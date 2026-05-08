// FILE: lib/screens/backup/backup_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Top-level "Backup & Export" screen. Three operationally distinct paths
// are exposed in three cards.
//
// (1) Local Export — always free, available to any user. Calls
// ExportService.writeExportToTempFile to serialize all user reloading data
// (recipes, firearms, brass lots, batches, custom components, process
// steps, load development sessions) into a JSON file inside the app's
// temp directory, then hands the file to share_plus. The user picks where
// the file actually lands (Files.app, AirDrop, email, Drive, anywhere) —
// the app never sees the destination. This is the privacy-pure escape
// hatch: even with no Pro subscription and no cloud account, every user
// can get all their data off-device.
//
// (2) iCloud Drive — Pro-gated, iOS-only. Lives in the app's iCloud
// container and goes through ICloudBackupService. Shows a friendly
// "Sign in to iCloud in Settings" message when the entitlement isn't
// enabled or the user isn't signed in.
//
// (3) Google Drive — Pro-gated, cross-platform. Uses
// DriveBackupService and writes into the user's per-app appDataFolder
// (invisible to the user's other Drive content). This is the cross-device
// restore path that works even on iOS — a user who buys a new Android
// phone and signs into the same Google account gets their recipes back.
//
// The cloud paths share a single passphrase setup flow. On backup we
// prompt for a passphrase (plus confirmation), encrypt the JSON with
// BackupCrypto, and upload the resulting blob. On restore we list
// available backups, let the user pick one, prompt for the passphrase,
// download, decrypt, and call ExportService.importFromJson. Passphrase
// entry has an 8-character minimum enforced inside the dialog. Restore
// shows a destructive-action confirmation and a merge-mode picker (skip
// duplicates vs overwrite) before any DB writes happen. Passphrases are
// NEVER persisted — they live only in memory for the duration of one
// operation, then are dropped.
//
// A backup-listing sub-screen lets the user view existing backups in
// either provider, with delete capability for cleanup.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// LoadOut's privacy posture (CLAUDE.md §13) promises no cloud sync of
// reloading data. That promise is a marketing claim; the cloud-backup
// feature lives here because (a) end-to-end encryption with a user-held
// passphrase keeps us compliant with that promise (we can't read the
// blob, neither can Apple/Google), and (b) reloaders need their data
// portable across phone replacements. Pro-gating the cloud tiers is
// what funds the development.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The encryption boundary has to be airtight: passphrases must never
// touch SharedPreferences, secure enclave, keychain, or disk. We
// deliberately re-prompt every operation rather than caching. Restore
// confirmation has to be unmistakable — a sloppy click and you wipe local
// data. Merge mode picker (skip vs overwrite) has to be presented so the
// user understands what each does without writing a paragraph of help
// text. Provider availability checks have to be done before each
// operation because the iCloud entitlement state can change between
// launch and now. Errors have to be classified into "decryption failed
// (wrong passphrase)" vs "import had partial errors" vs "fatal abort"
// because the right user response is different in each case.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/home/home_screen.dart (drawer destination)
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// Reads the entire AppDatabase via ExportService.exportToJson. Writes a
// temp JSON file via writeExportToTempFile. Calls share_plus.
// CloudBackupProvider implementations talk to iCloud / Google Drive over
// the network. BackupCrypto runs Argon2id key derivation + AES-GCM. On
// restore: writes new rows into AppDatabase via ExportService.importFromJson.
// EntitlementNotifier read for paywall gating.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../database/database.dart';
import '../../repositories/recipe_repository.dart';
import '../../services/backup_crypto.dart';
import '../../services/cloud_backup.dart';
import '../../services/csv_import_service.dart';
import '../../services/drive_backup_service.dart';
import '../../services/entitlement_notifier.dart';
import '../../services/export_service.dart';
import '../../services/icloud_backup_service.dart';
import '../../services/onedrive_backup_service.dart';
import '../../services/onedrive_config.dart';
import '../auth/login_screen.dart';
import '../paywall/paywall_screen.dart';
import '../recipes/smart_import_screen.dart';

/// Top-level "Backup & Export" destination reachable from the home drawer.
///
/// Free users see a paywall card explaining what Pro unlocks; the local
/// JSON export tile is always free. Pro users see three cards:
///
///   - Local Export (always free): builds a JSON file and hands it to
///     `share_plus` so the user can drop it anywhere they like.
///   - iCloud Drive (iOS only): encrypted blob in the app's iCloud
///     container. Shows a "Sign in to iCloud in Settings" message when
///     the entitlement isn't enabled / the user isn't signed in.
///   - Google Drive (cross-platform): encrypted blob in the user's per-app
///     `appDataFolder`. Cross-device restore path even on iOS.
///
/// Passphrases are NEVER persisted — neither to disk, secure enclave,
/// keychain, nor SharedPreferences. The Backup screen holds them in
/// memory for the duration of a single operation, then drops them.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  late final ExportService _export;
  late final ICloudBackupService _icloud;
  late final DriveBackupService _drive;
  late final OneDriveBackupService _onedrive;

  bool _busy = false;
  String? _statusMessage;

  /// Per-session dismissal of the sign-in nudge for anonymous /
  /// signed-out users. Resets next time the screen is opened.
  bool _signInPromptDismissed = false;

  /// Auth-state subscription so the soft prompt rebuilds away after the
  /// user signs in (or back to anonymous after sign-out) without the
  /// user having to leave and re-open this screen.
  StreamSubscription<User?>? _authSub;

  @override
  void initState() {
    super.initState();
    final db = context.read<AppDatabase>();
    _export = ExportService(db);
    _icloud = ICloudBackupService();
    _drive = DriveBackupService();
    _onedrive = OneDriveBackupService();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPro = context.watch<EntitlementNotifier>().isPro;
    final user = FirebaseAuth.instance.currentUser;
    final needsSignInPrompt =
        (user == null || user.isAnonymous) && !_signInPromptDismissed;
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & Export')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (needsSignInPrompt) ...[
              _SignInPromptCard(
                onSignIn: _openSignIn,
                onDismiss: () =>
                    setState(() => _signInPromptDismissed = true),
              ),
              const SizedBox(height: 16),
            ],
            _PrivacyBlurb(),
            const SizedBox(height: 16),
            _LocalExportCard(
              busy: _busy,
              onShare: _runLocalExport,
            ),
            const SizedBox(height: 16),
            _CsvImportCard(
              busy: _busy,
              onSmartImport: _runSmartImport,
              onQuickImport: _runQuickCsvImport,
            ),
            const SizedBox(height: 16),
            if (!isPro) ...[
              _ProUpsellCard(onUpgrade: _openPaywall),
            ] else ...[
              if (Platform.isIOS) ...[
                _CloudCard(
                  provider: _icloud,
                  busy: _busy,
                  onBackup: () => _runCloudBackup(_icloud),
                  onRestore: () => _runCloudRestore(_icloud),
                  onListAndManage: () => _openCloudList(_icloud),
                ),
                const SizedBox(height: 16),
              ],
              _CloudCard(
                provider: _drive,
                busy: _busy,
                onBackup: () => _runCloudBackup(_drive),
                onRestore: () => _runCloudRestore(_drive),
                onListAndManage: () => _openCloudList(_drive),
              ),
              if (!OneDriveConfig.isPlaceholder) ...[
                const SizedBox(height: 16),
                _CloudCard(
                  provider: _onedrive,
                  busy: _busy,
                  onBackup: () => _runCloudBackup(_onedrive),
                  onRestore: () => _runCloudRestore(_onedrive),
                  onListAndManage: () => _openCloudList(_onedrive),
                ),
              ],
            ],
            if (_statusMessage != null) ...[
              const SizedBox(height: 16),
              _StatusBanner(message: _statusMessage!),
            ],
            const SizedBox(height: 24),
            if (_busy)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _openSignIn() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  // ─────────────── operations ───────────────

  Future<void> _runLocalExport() async {
    await _withBusy(() async {
      final file = await _export.writeExportToTempFile();
      // Hand off to the system share sheet. The user picks where the
      // file ends up — Files.app, AirDrop, email, Drive, anywhere.
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'LoadOut export',
      );
      _setStatus(
        'Export ready — pick a destination from the share sheet.',
      );
    }, errorPrefix: 'Export failed');
  }

  /// "Import from CSV / Excel" entry. Pushes the Smart Import wizard,
  /// which walks the user through file pick → header detection →
  /// column mapping → import. Always free, never Pro-gated. The
  /// previous one-shot CSV importer (`CsvImportService`) is still
  /// exposed for power users via the bottom-row "Quick CSV import"
  /// affordance below.
  Future<void> _runSmartImport() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SmartImportScreen()),
    );
    if (!mounted) return;
    _setStatus('Smart Import finished.');
  }

  /// Legacy one-shot CSV importer kept as a fallback for the
  /// power-user flow ("my columns are named exactly the way you
  /// expect; just go"). Reads the file, parses, prompts a single
  /// confirmation dialog, then imports.
  Future<void> _runQuickCsvImport() async {
    final repo = context.read<RecipeRepository>();

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv'],
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return;
    final path = picked.files.single.path;
    if (path == null) {
      _setStatus('Could not read the selected file path.');
      return;
    }

    await _withBusy(() async {
      final file = File(path);
      String content;
      try {
        content = await file.readAsString();
      } catch (_) {
        // Fall back to latin-1 if utf-8 fails — Excel often saves CSVs
        // in CP-1252.
        content = await file.readAsString(encoding: latin1);
      }

      final service = CsvImportService(repo);
      final preview = service.parsePreview(content);

      if (preview.hasFatalError) {
        _setStatus(preview.fatalError!);
        return;
      }
      if (!preview.canImport) {
        _setStatus(
          'No recipe-name column was detected. Use Smart Import for '
          'spreadsheets with custom column names, or rename a column '
          'to "Name" / "Recipe Name" first.',
        );
        return;
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => _CsvImportPreviewDialog(preview: preview),
      );
      if (confirmed != true) return;

      final result = await service.import(content);
      final pieces = <String>[
        '${result.imported} recipes imported.',
        if (result.skipped > 0)
          '${result.skipped} rows skipped due to missing recipe name.',
        if (result.hasErrors)
          '${result.errors.length} row issue(s) — see logs.',
      ];
      if (kDebugMode && result.hasErrors) {
        for (final e in result.errors) {
          debugPrint('CSV import warning: $e');
        }
      }
      _setStatus(pieces.join(' '));
    }, errorPrefix: 'CSV import failed');
  }

  Future<void> _runCloudBackup(CloudBackupProvider provider) async {
    if (!await provider.isAvailable()) {
      _setStatus(_unavailableMessage(provider));
      return;
    }
    final passphrase = await _promptForPassphrase(
      title: 'Set Backup Passphrase',
      confirmation: true,
    );
    if (passphrase == null) return;

    await _withBusy(() async {
      final json = await _export.exportToJson();
      final crypto = BackupCrypto();
      final blob = await crypto.encrypt(passphrase, json);
      await provider.upload(blob);
      _setStatus(
        'Backup uploaded to ${provider.displayName} '
        '(${_formatSize(blob.length)}).',
      );
    }, errorPrefix: '${provider.displayName} backup failed');
  }

  Future<void> _runCloudRestore(CloudBackupProvider provider) async {
    if (!await provider.isAvailable()) {
      _setStatus(_unavailableMessage(provider));
      return;
    }
    await _withBusy(() async {
      final backups = await provider.list();
      if (!mounted) return;
      if (backups.isEmpty) {
        _setStatus('No backups found in ${provider.displayName}.');
        return;
      }
      final picked = await _pickBackup(backups, provider.displayName);
      if (picked == null) return;
      final confirmed = await _confirmDestructiveRestore(picked);
      if (confirmed != true) return;
      final passphrase = await _promptForPassphrase(
        title: 'Enter Passphrase',
        confirmation: false,
      );
      if (passphrase == null) return;
      final mode = await _pickMergeMode();
      if (mode == null) return;

      final blob = await provider.download(picked);
      final crypto = BackupCrypto();
      late final String json;
      try {
        json = await crypto.decrypt(passphrase, Uint8List.fromList(blob));
      } on BackupDecryptException catch (e) {
        _setStatus(e.message);
        return;
      }
      final summary = await _export.importFromJson(json, mode: mode);
      if (summary.fatalError != null) {
        _setStatus('Restore aborted: ${summary.fatalError}');
        return;
      }
      _setStatus(
        'Restore complete — added ${summary.totalAdded} '
        'rows, skipped ${summary.totalSkipped}'
        '${summary.hasErrors ? " (with errors)" : ""}.',
      );
    }, errorPrefix: '${provider.displayName} restore failed');
  }

  Future<void> _openCloudList(CloudBackupProvider provider) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _CloudBackupListScreen(provider: provider),
      ),
    );
  }

  // ─────────────── helpers ───────────────

  String _unavailableMessage(CloudBackupProvider provider) {
    if (provider is ICloudBackupService) {
      return 'iCloud Drive is unavailable — make sure iCloud Drive is '
          'turned on in Settings → [your name] → iCloud, and that '
          'this app has iCloud access.';
    }
    if (provider is OneDriveBackupService) {
      return 'OneDrive is unavailable — open Cloud Sync settings to '
          'connect your Microsoft account.';
    }
    return '${provider.displayName} is unavailable — sign in to your '
        'Google account to back up here.';
  }

  Future<void> _withBusy(
    Future<void> Function() action, {
    required String errorPrefix,
  }) async {
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    try {
      await action();
    } catch (e, stack) {
      if (kDebugMode) {
        debugPrint('$errorPrefix: $e');
        debugPrintStack(stackTrace: stack);
      }
      // We deliberately keep error messages generic — never include any
      // string that could leak the passphrase.
      _setStatus('$errorPrefix: ${_redact(e)}');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  void _setStatus(String message) {
    if (!mounted) return;
    setState(() => _statusMessage = message);
  }

  /// Strip anything that looks like it could contain a passphrase from an
  /// error string. Cheap belt-and-suspenders — [BackupCrypto] already
  /// avoids echoing it, but third-party plugin errors might.
  String _redact(Object e) {
    final s = e.toString();
    return s.replaceAll(RegExp(r'passphrase[^,)\]]*'), 'passphrase=<redacted>');
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  Future<String?> _promptForPassphrase({
    required String title,
    required bool confirmation,
  }) async {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _PassphraseDialog(
        title: title,
        confirmation: confirmation,
      ),
    );
  }

  Future<CloudBackupMetadata?> _pickBackup(
    List<CloudBackupMetadata> options,
    String providerName,
  ) async {
    return showDialog<CloudBackupMetadata>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Pick a $providerName Backup'),
        children: [
          for (final meta in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, meta),
              child: ListTile(
                title: Text(meta.filename),
                subtitle: Text(
                  '${_formatSize(meta.size)} · '
                  '${meta.modifiedAt?.toLocal() ?? "unknown date"}',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<bool?> _confirmDestructiveRestore(CloudBackupMetadata meta) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore From Backup?'),
        content: Text(
          'You are about to import "${meta.filename}". Existing rows that '
          'share an id with the backup will be either kept or overwritten '
          '(your choice next). New rows will be added.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  Future<ImportMergeMode?> _pickMergeMode() async {
    return showDialog<ImportMergeMode>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Conflict Mode'),
        content: const Text(
          'When a row in the backup has the same id as something already in '
          'your database, what should LoadOut do?',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, ImportMergeMode.skipDuplicates),
            child: const Text('Skip Duplicates'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ImportMergeMode.overwrite),
            child: const Text('Overwrite'),
          ),
        ],
      ),
    );
  }

  void _openPaywall() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const PaywallScreen(),
        fullscreenDialog: true,
      ),
    );
  }
}

// ─────────────────────── Sub-widgets ───────────────────────

/// Soft, dismissible prompt shown to anonymous / signed-out users on the
/// Backups screen. Sign-in is optional everywhere else in the app —
/// cloud backup is the one feature that legitimately needs an account so
/// the encrypted blob has a stable place to live across devices. The
/// prompt is intentionally non-blocking: local JSON export still works
/// for guests (privacy posture, CLAUDE.md §13).
class _SignInPromptCard extends StatelessWidget {
  const _SignInPromptCard({
    required this.onSignIn,
    required this.onDismiss,
  });

  final VoidCallback onSignIn;
  final VoidCallback onDismiss;

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
                Icon(
                  Icons.cloud_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Sign in for cloud backup',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              "Sign in to enable cloud backup of your loads, firearms, "
              'and brass. Your data is encrypted with a passphrase only '
              'you know — we never see your reloading data.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: onSignIn,
                  icon: const Icon(Icons.login),
                  label: const Text('Sign in'),
                ),
                TextButton(
                  onPressed: onDismiss,
                  child: const Text('Continue without backup'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

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
                Icon(Icons.lock_outline, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Your Data, Your Custody',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Local export is a plain JSON file you control. Cloud backups '
              'are encrypted on this device with a passphrase only you '
              'know — LoadOut never sees the encrypted blob and never '
              'stores your passphrase. Forgotten passphrases cannot be '
              'recovered, so write yours down somewhere safe.',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _LocalExportCard extends StatelessWidget {
  const _LocalExportCard({required this.busy, required this.onShare});

  final bool busy;
  final VoidCallback onShare;

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
                Icon(Icons.file_download_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Local Export',
                    style: theme.textTheme.titleMedium),
                const Spacer(),
                Chip(
                  label: const Text('Free'),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: theme.colorScheme.primary.withValues(
                    alpha: 0.12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Build a plain-JSON copy of every recipe, firearm, lot, '
              'and custom field. The file is handed to your share '
              'sheet — keep it locally, AirDrop it, or upload it '
              'wherever you like.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: busy ? null : onShare,
                icon: const Icon(Icons.ios_share),
                label: const Text('Export & Share'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProUpsellCard extends StatelessWidget {
  const _ProUpsellCard({required this.onUpgrade});
  final VoidCallback onUpgrade;

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
                Icon(Icons.workspace_premium_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Encrypted Cloud Backup',
                    style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'LoadOut Pro unlocks end-to-end encrypted backups to your '
              'own iCloud Drive (iOS) or Google Drive (any platform). '
              'Files are encrypted on this device with a passphrase '
              'only you know — LoadOut never holds the blob.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: onUpgrade,
                child: const Text('See Pro'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CloudCard extends StatefulWidget {
  const _CloudCard({
    required this.provider,
    required this.busy,
    required this.onBackup,
    required this.onRestore,
    required this.onListAndManage,
  });

  final CloudBackupProvider provider;
  final bool busy;
  final VoidCallback onBackup;
  final VoidCallback onRestore;
  final VoidCallback onListAndManage;

  @override
  State<_CloudCard> createState() => _CloudCardState();
}

class _CloudCardState extends State<_CloudCard> {
  bool? _available;

  @override
  void initState() {
    super.initState();
    _refreshAvailability();
  }

  Future<void> _refreshAvailability() async {
    final available = await widget.provider.isAvailable();
    if (!mounted) return;
    setState(() => _available = available);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final providerIcon = widget.provider is ICloudBackupService
        ? Icons.cloud_outlined
        : widget.provider is OneDriveBackupService
            ? Icons.cloud_circle_outlined
            : Icons.cloud_queue_outlined;
    final providerBlurb = widget.provider is ICloudBackupService
        ? 'Encrypted blob lives in your iCloud Drive under '
            'Files.app → LoadOut → Backups. Apple sees an opaque '
            'file; only your passphrase unlocks it.'
        : widget.provider is OneDriveBackupService
            ? 'Encrypted blob lives in a per-app OneDrive folder only '
                'LoadOut can read. Cross-platform — perfect for users '
                'with a Microsoft 365 subscription.'
            : 'Encrypted blob lives in a per-app Drive folder only '
                'LoadOut can read. Works the same on iOS and Android, '
                'so it is the cross-device restore path.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(providerIcon, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(widget.provider.displayName,
                    style: theme.textTheme.titleMedium),
                const Spacer(),
                _StatusChip(available: _available),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              providerBlurb,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: widget.busy ? null : widget.onBackup,
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Back Up Now'),
                ),
                OutlinedButton.icon(
                  onPressed: widget.busy ? null : widget.onRestore,
                  icon: const Icon(Icons.restore),
                  label: const Text('Restore'),
                ),
                OutlinedButton.icon(
                  onPressed: widget.busy ? null : widget.onListAndManage,
                  icon: const Icon(Icons.list_alt),
                  label: const Text('Manage'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.available});
  final bool? available;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (available == null) {
      return const SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    final ok = available!;
    return Chip(
      visualDensity: VisualDensity.compact,
      backgroundColor: ok
          ? theme.colorScheme.primary.withValues(alpha: 0.12)
          : theme.colorScheme.errorContainer,
      label: Text(ok ? 'Ready' : 'Unavailable'),
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

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({
    required this.title,
    required this.confirmation,
  });

  final String title;
  final bool confirmation;

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
    // Wipe the controllers on tear-down so the passphrase doesn't linger
    // in the heap any longer than necessary.
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
      final result = _ctrl1.text;
      Navigator.of(context).pop(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _ctrl1,
              obscureText: _obscure1,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Passphrase',
                suffixIcon: IconButton(
                  icon: Icon(_obscure1 ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscure1 = !_obscure1),
                ),
              ),
              validator: _validateFirst,
              onFieldSubmitted: (_) => _submit(),
            ),
            if (widget.confirmation) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _ctrl2,
                obscureText: _obscure2,
                decoration: InputDecoration(
                  labelText: 'Confirm Passphrase',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure2 ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () => setState(() => _obscure2 = !_obscure2),
                  ),
                ),
                validator: _validateSecond,
                onFieldSubmitted: (_) => _submit(),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'LoadOut cannot recover this passphrase. Save it somewhere '
              'you trust before continuing.',
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
        FilledButton(
          onPressed: _submit,
          child: const Text('OK'),
        ),
      ],
    );
  }
}

/// Per-provider list/manage screen. Lets the user nuke old backups one
/// by one. We surface only filename + size + modified date — enough to
/// disambiguate, nothing that could leak data.
class _CloudBackupListScreen extends StatefulWidget {
  const _CloudBackupListScreen({required this.provider});
  final CloudBackupProvider provider;

  @override
  State<_CloudBackupListScreen> createState() => _CloudBackupListScreenState();
}

class _CloudBackupListScreenState extends State<_CloudBackupListScreen> {
  late Future<List<CloudBackupMetadata>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.provider.list();
  }

  Future<void> _refresh() async {
    setState(() {
      _future = widget.provider.list();
    });
    await _future;
  }

  Future<void> _confirmAndDelete(CloudBackupMetadata meta) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Backup?'),
        content: Text(
          'Permanently delete "${meta.filename}" from '
          '${widget.provider.displayName}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.provider.delete(meta);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.provider.displayName} Backups'),
      ),
      body: FutureBuilder<List<CloudBackupMetadata>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Error: ${snap.error}'),
              ),
            );
          }
          final items = snap.data ?? const <CloudBackupMetadata>[];
          if (items.isEmpty) {
            return const Center(child: Text('No backups yet.'));
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final m = items[i];
                return ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: Text(m.filename),
                  subtitle: Text(
                    '${_formatSize(m.size)} · '
                    '${m.modifiedAt?.toLocal() ?? "unknown date"}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _confirmAndDelete(m),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// "Import from CSV / Excel" tile on the Backup screen. Always free —
/// the goal is to make it dead simple for an Excel reloader to bring
/// their data across, regardless of how their column names are
/// labeled. The primary action is Smart Import (mapping wizard);
/// the secondary "Quick CSV import" is for power users whose CSV
/// already has standard column names.
class _CsvImportCard extends StatelessWidget {
  const _CsvImportCard({
    required this.busy,
    required this.onSmartImport,
    required this.onQuickImport,
  });

  final bool busy;
  final VoidCallback onSmartImport;
  final VoidCallback onQuickImport;

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
                Icon(Icons.table_chart_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Import from CSV / Excel',
                    style: theme.textTheme.titleMedium),
                const Spacer(),
                Chip(
                  label: const Text('Free'),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: theme.colorScheme.primary.withValues(
                    alpha: 0.12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Already track your loads in a spreadsheet? Bring them in '
              'with Smart Import — it shows you each column, suggests '
              'how it maps to LoadOut, and lets you confirm. Works with '
              'any column names.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: busy ? null : onSmartImport,
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('Smart Import (CSV / Excel)'),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: busy ? null : onQuickImport,
                icon: const Icon(Icons.upload_file),
                label: const Text('Quick CSV import (power users)'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pre-import preview dialog. Shows the user the detected column
/// mapping and any unrecognised headers, then asks them to confirm
/// before any rows are written.
class _CsvImportPreviewDialog extends StatelessWidget {
  const _CsvImportPreviewDialog({required this.preview});

  final CsvImportPreview preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Confirm Import'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Found ${preview.totalRows} row'
              '${preview.totalRows == 1 ? '' : 's'} in the CSV.',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 12),
            Text(
              'Detected columns:',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final c in preview.detectedColumns)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(
                      Icons.check,
                      color: theme.colorScheme.primary,
                      size: 16,
                    ),
                    label: Text(c.field.label),
                  ),
              ],
            ),
            if (preview.unrecognisedHeaders.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Ignored columns:',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final h in preview.unrecognisedHeaders)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text(
                        h.isEmpty ? '(blank)' : h,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Rows missing a recipe name will be skipped. Numeric '
              'cells with extra text like "41.5gr" will still be '
              'imported. You can edit any field afterwards.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text('Import ${preview.totalRows}'),
        ),
      ],
    );
  }
}
