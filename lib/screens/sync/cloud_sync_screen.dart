// FILE: lib/screens/sync/cloud_sync_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// User-facing surface for the Cloud Sync (Pro) feature. Lives behind
// Settings → "Cloud Sync (Pro)" and gates the [CloudSyncService] toggles
// so a free user never accidentally enables continuous sync without a
// paywall hop. The screen lets the user:
//
//   * pick a cloud provider (iCloud / Google Drive / OneDrive),
//   * type the end-to-end-encryption passphrase once and have it
//     cached in the platform Keychain / Keystore,
//   * turn sync on (Pro-gated) or off (always available),
//   * see the current status — "Syncing…" / "Up to date · 14:23" /
//     "Last remote update · 13:51" — and trigger an explicit
//     reconcile.
//
// The encryption story is unchanged from CLAUDE.md §13. The Settings →
// Backups screen still owns the manual one-shot Backup / Restore
// path; this screen only adds continuous orchestration on top.
//
// FREE USERS see the same controls but the action button is replaced
// with a paywall CTA. They keep the manual Backup screen.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// LoadOut already shipped a Pro-gated encrypted backup (manual). The
// next obvious user expectation is "set it and forget it" — log a
// load on phone, see it on tablet without doing anything. That
// requires:
//   1. a screen that owns the on/off + provider + passphrase state, and
//   2. a service (CloudSyncService) that owns the actual sync mechanics.
// This file is (1).
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/settings/settings_screen.dart pushes this screen from
//   the "Cloud Sync (Pro)" tile.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - All persistence happens inside CloudSyncService (SharedPreferences
//   for the on/off bit + provider id + timestamps; secure-storage for
//   the passphrase).
// - Tapping "Sync Now" launches `CloudSyncService.reconcile`, which
//   touches the active provider's network endpoint.
// - Free users tapping "Enable" get bounced to the paywall via
//   `ensurePro`.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/backup_crypto.dart';
import '../../services/cloud_sync_service.dart';
import '../../services/entitlement_notifier.dart';
import '../../widgets/pro_gate.dart';

/// Settings → Cloud Sync (Pro). Wraps [CloudSyncService] in a
/// dedicated screen so the controls don't clutter the main Settings
/// list.
class CloudSyncScreen extends StatefulWidget {
  const CloudSyncScreen({super.key});

  @override
  State<CloudSyncScreen> createState() => _CloudSyncScreenState();
}

class _CloudSyncScreenState extends State<CloudSyncScreen> {
  bool _busy = false;
  String? _status;
  String _selectedProvider = SyncProviderId.icloud;

  @override
  void initState() {
    super.initState();
    final svc = context.read<CloudSyncService>();
    if (svc.activeProviderId != null) {
      _selectedProvider = svc.activeProviderId!;
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<CloudSyncService>();
    final isPro = context.watch<EntitlementNotifier>().isPro;
    return Scaffold(
      appBar: AppBar(title: const Text('Cloud Sync')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _PrivacyBlurb(),
            const SizedBox(height: 16),
            _StatusCard(service: svc),
            const SizedBox(height: 16),
            _ProviderPickerCard(
              selected: _selectedProvider,
              enabled: !svc.isEnabled,
              onChanged: (p) => setState(() => _selectedProvider = p),
            ),
            const SizedBox(height: 16),
            _ActionsCard(
              isPro: isPro,
              isEnabled: svc.isEnabled,
              onEnable: () => _enable(svc),
              onDisable: () => _disable(svc),
              onSyncNow: () => _syncNow(svc),
            ),
            if (_status != null) ...[
              const SizedBox(height: 16),
              _StatusBanner(message: _status!),
            ],
            if (_busy) ...[
              const SizedBox(height: 16),
              const Center(child: CircularProgressIndicator()),
            ],
            const SizedBox(height: 24),
            _DangerNote(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ─────────────── actions ───────────────

  Future<void> _enable(CloudSyncService svc) async {
    if (!await ensurePro(context)) return;
    final passphrase = await _promptForPassphrase();
    if (passphrase == null) return;
    setState(() => _busy = true);
    try {
      await svc.enable(
        providerId: _selectedProvider,
        passphrase: passphrase,
      );
      _setStatus('Cloud Sync enabled. Initial pull complete.');
    } catch (e) {
      _setStatus('Could not enable: ${_redact(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disable(CloudSyncService svc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disable Cloud Sync?'),
        content: const Text(
          'Your data on this device stays. The encrypted blob in your '
          'cloud stays. You can turn sync back on later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Disable'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await svc.disable();
      _setStatus('Cloud Sync disabled.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow(CloudSyncService svc) async {
    setState(() => _busy = true);
    try {
      final result = await svc.reconcile();
      switch (result.outcome) {
        case SyncPullOutcome.merged:
          final s = result.summary;
          _setStatus(
            s == null
                ? 'Sync complete.'
                : 'Sync complete — added ${s.totalAdded}, '
                    'skipped ${s.totalSkipped}'
                    '${s.hasErrors ? " (with errors)" : ""}.',
          );
          break;
        case SyncPullOutcome.notFound:
          _setStatus(
            'No remote blob yet — pushed the current device as the '
            'first canonical copy.',
          );
          break;
        case SyncPullOutcome.passphraseMismatch:
          _setStatus(
            result.message ??
                'Could not decrypt remote blob. Check the passphrase.',
          );
          break;
        case SyncPullOutcome.error:
          _setStatus('Sync failed: ${result.message ?? "unknown error"}.');
          break;
      }
    } catch (e) {
      _setStatus('Sync failed: ${_redact(e)}.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setStatus(String message) {
    if (!mounted) return;
    setState(() => _status = message);
  }

  String _redact(Object e) {
    final s = e.toString();
    return s.replaceAll(RegExp(r'passphrase[^,)\]]*'),
        'passphrase=<redacted>');
  }

  Future<String?> _promptForPassphrase() async {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const _PassphraseDialog(),
    );
  }
}

// ─────────────────────── Sub-widgets ───────────────────────

class _PrivacyBlurb extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.shield_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('End-to-End Encrypted',
                    style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Cloud Sync uses the same encryption as a manual backup. '
              'Your data is encrypted on this device with a passphrase '
              'only you know, then uploaded to your own iCloud / Google '
              'Drive / OneDrive. LoadOut never sees the encrypted blob '
              'and runs no backend that receives reloading data.',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.service});

  final CloudSyncService service;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ValueListenableBuilder<SyncStatus>(
                  valueListenable: service.status,
                  builder: (context, status, _) =>
                      _StatusDot(status: status, isEnabled: service.isEnabled),
                ),
                const SizedBox(width: 8),
                Text('Status', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<SyncStatus>(
              valueListenable: service.status,
              builder: (context, status, _) {
                return Text(
                  _humanStatus(service.isEnabled, status),
                  style: theme.textTheme.bodyMedium,
                );
              },
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<DateTime?>(
              valueListenable: service.lastSyncedAt,
              builder: (context, when, _) => Text(
                when == null
                    ? 'Last synced: never'
                    : 'Last synced: ${_formatDateTime(when)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 4),
            ValueListenableBuilder<DateTime?>(
              valueListenable: service.lastRemoteUpdateAt,
              builder: (context, when, _) => Text(
                when == null
                    ? 'Remote update: unknown'
                    : 'Remote update: ${_formatDateTime(when)}',
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

  static String _humanStatus(bool enabled, SyncStatus status) {
    if (!enabled) return 'Sync is off on this device.';
    switch (status) {
      case SyncStatus.idle:
        return 'Up to date.';
      case SyncStatus.syncingUp:
        return 'Syncing — uploading your latest changes…';
      case SyncStatus.syncingDown:
        return 'Syncing — pulling changes from the cloud…';
      case SyncStatus.conflict:
        return 'Could not decrypt the remote blob. Re-enter your '
            'passphrase to continue.';
      case SyncStatus.error:
        return 'Last attempt failed. Tap "Sync Now" to retry.';
    }
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status, required this.isEnabled});

  final SyncStatus status;
  final bool isEnabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Color color;
    if (!isEnabled) {
      color = scheme.onSurfaceVariant.withValues(alpha: 0.5);
    } else {
      switch (status) {
        case SyncStatus.idle:
          color = scheme.primary;
          break;
        case SyncStatus.syncingUp:
        case SyncStatus.syncingDown:
          color = const Color(0xFFF59E0B); // amber
          break;
        case SyncStatus.conflict:
        case SyncStatus.error:
          color = scheme.error;
          break;
      }
    }
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _ProviderPickerCard extends StatelessWidget {
  const _ProviderPickerCard({
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final String selected;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_queue_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Provider', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Choose where the encrypted blob lives. To change provider, '
              'disable sync first.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            for (final entry in const [
              (SyncProviderId.icloud, 'iCloud Drive (iOS)'),
              (SyncProviderId.gdrive, 'Google Drive'),
              (SyncProviderId.onedrive, 'OneDrive'),
            ])
              RadioListTile<String>(
                title: Text(entry.$2),
                value: entry.$1,
                // ignore: deprecated_member_use
                groupValue: selected,
                // ignore: deprecated_member_use
                onChanged: enabled ? (v) => v == null ? null : onChanged(v) : null,
              ),
          ],
        ),
      ),
    );
  }
}

class _ActionsCard extends StatelessWidget {
  const _ActionsCard({
    required this.isPro,
    required this.isEnabled,
    required this.onEnable,
    required this.onDisable,
    required this.onSyncNow,
  });

  final bool isPro;
  final bool isEnabled;
  final VoidCallback onEnable;
  final VoidCallback onDisable;
  final VoidCallback onSyncNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.tune_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Controls', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (!isPro)
                  Chip(
                    label: const Text('Pro'),
                    visualDensity: VisualDensity.compact,
                    backgroundColor:
                        theme.colorScheme.primary.withValues(alpha: 0.12),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (!isEnabled) ...[
              Text(
                isPro
                    ? 'Cloud Sync is off. Turn it on to keep this device '
                        'in lock-step with your other devices.'
                    : 'Continuous Cloud Sync is a Pro feature. Free '
                        'users keep the manual encrypted backup on the '
                        'Backup & Export screen.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: onEnable,
                  icon: const Icon(Icons.sync),
                  label: Text(isPro ? 'Enable Cloud Sync' : 'See Pro'),
                ),
              ),
            ] else ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: onSyncNow,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Sync Now'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onDisable,
                    icon: const Icon(Icons.cloud_off_outlined),
                    label: const Text('Disable'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _DangerNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_outlined,
              color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Lose your passphrase and the synced data is unrecoverable. '
              'LoadOut cannot reset it for you. Save it somewhere safe.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog();

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _formKey = GlobalKey<FormState>();
  final _ctrl1 = TextEditingController();
  final _ctrl2 = TextEditingController();
  bool _obscure1 = true;
  bool _obscure2 = true;

  @override
  void dispose() {
    _ctrl1.text = '';
    _ctrl2.text = '';
    _ctrl1.dispose();
    _ctrl2.dispose();
    super.dispose();
  }

  String? _validateFirst(String? value) {
    if (value == null || value.length < BackupCrypto.minPassphraseLength) {
      return 'Use at least ${BackupCrypto.minPassphraseLength} characters.';
    }
    return null;
  }

  String? _validateSecond(String? value) {
    if (value != _ctrl1.text) return 'Passphrases do not match.';
    return null;
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pop(_ctrl1.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set Sync Passphrase'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _ctrl1,
              autofocus: true,
              obscureText: _obscure1,
              decoration: InputDecoration(
                labelText: 'Passphrase',
                suffixIcon: IconButton(
                  icon: Icon(_obscure1
                      ? Icons.visibility_off
                      : Icons.visibility),
                  onPressed: () => setState(() => _obscure1 = !_obscure1),
                ),
              ),
              validator: _validateFirst,
              onFieldSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _ctrl2,
              obscureText: _obscure2,
              decoration: InputDecoration(
                labelText: 'Confirm Passphrase',
                suffixIcon: IconButton(
                  icon: Icon(_obscure2
                      ? Icons.visibility_off
                      : Icons.visibility),
                  onPressed: () => setState(() => _obscure2 = !_obscure2),
                ),
              ),
              validator: _validateSecond,
              onFieldSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            Text(
              'On other devices, enter the same passphrase here to '
              'sync. Memorize it — losing it makes synced data '
              'unrecoverable.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Continue')),
      ],
    );
  }
}

String _formatDateTime(DateTime dt) {
  final local = dt.toLocal();
  final hour24 = local.hour;
  final hour12 = hour24 == 0
      ? 12
      : hour24 > 12
          ? hour24 - 12
          : hour24;
  final minute = local.minute.toString().padLeft(2, '0');
  final ampm = hour24 < 12 ? 'AM' : 'PM';
  return '${local.year}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '$hour12:$minute $ampm';
}
