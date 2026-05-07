// FILE: lib/screens/settings/settings_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The Settings screen — host for app-level toggles plus the Help & Support
// section that surfaces account-recovery flows and the destructive
// "Delete my data" path. Reached from the Home drawer.
//
// At launch v1 the screen ships with two sections:
//
// 1. Editing — a single `SwitchListTile` for the autosave toggle.
// 2. Help & Support — Email support (mailto with app version + platform),
//    Restore from backup (pushes BackupScreen), Restore purchases (calls
//    PurchasesService.restorePurchases and surfaces the result via
//    snackbar), Privacy Policy, Terms / Disclaimer, and a triple-confirm
//    "Delete my data" flow that wipes user reloading data via
//    `AppDatabase.wipeUserData()`, signs out of Firebase, and bounces the
//    user back to Home.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// LoadOut accumulates app-level preferences (autosave, soon: theme,
// units, etc.). Until now there was no settings entry point — most
// preferences lived inside individual screens. The dedicated screen
// gives toggles a discoverable home and avoids cluttering each form
// with its own gear, and parks the support flows in one place.
//
// The decision to keep sign-in optional (CLAUDE.md "User auth posture")
// makes account-recovery and restore-purchases especially important to
// surface here — a user who never signed in but later wants Pro to
// follow their App Store / Play Store account needs a frictionless
// "Restore Purchases" tap somewhere obvious.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/home/home_screen.dart — the drawer pushes
//   `SettingsScreen()` from the "Settings" list tile.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Calls `AutoSaveService.setEnabled(...)` when the toggle changes,
//   which writes to `SharedPreferences` and notifies listeners.
// - Opens `mailto:` URLs via url_launcher for the support tile and the
//   email-link recovery affordance.
// - Calls `PurchasesService.restorePurchases()` and `EntitlementNotifier.refresh()`.
// - The delete-my-data flow calls `AppDatabase.wipeUserData()` (drops
//   every row in user-data tables) and `AuthService.signOut()`.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../database/database.dart';
import '../../services/auth_service.dart';
import '../../services/auto_save_service.dart';
import '../../services/beginner_mode_service.dart';
import '../../services/entitlement_notifier.dart';
import '../../services/purchases_service.dart';
import '../backup/backup_screen.dart';
import '../disclaimer/disclaimer_screen.dart';
import '../privacy/privacy_screen.dart';

/// Hardcoded for the support-mailto body. Kept in lockstep with
/// `pubspec.yaml`'s `version:` field — bump both together at release time.
const String _appVersion = '1.0.0+1';

/// Address used by the Help & Support and email-link recovery flows.
/// Centralized so a future change only edits one constant.
const String _supportEmail = 'support@johnsondigital.com';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final service = context.watch<AutoSaveService>();
    final beginner = context.watch<BeginnerModeService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          children: [
            const _SectionHeader('Experience'),
            SwitchListTile(
              secondary: const Icon(Icons.school_outlined),
              title: const Text('Beginner Mode'),
              subtitle: const Text(
                'Recipe forms open with just the basics, less-common '
                'fields show short explainers, and the Glossary stays one '
                'tap away. Turn off for the full power-user view.',
              ),
              value: beginner.isEnabled,
              onChanged: (v) {
                // ignore: discarded_futures
                beginner.setEnabled(v);
              },
            ),
            const _SectionHeader('Editing'),
            SwitchListTile(
              secondary: const Icon(Icons.bolt_outlined),
              title: const Text('Auto-save forms'),
              subtitle: const Text(
                'Your edits save automatically as you type, so you never have '
                'to scroll to a save button. Turn off if you prefer manual '
                'saves while experimenting.',
              ),
              value: service.isEnabled,
              onChanged: (v) {
                // ignore: discarded_futures
                service.setEnabled(v);
              },
            ),
            const _SectionHeader('Help & Support'),
            ListTile(
              leading: const Icon(Icons.mail_outline),
              title: const Text('Email support'),
              subtitle: const Text(
                'Open your mail app with a draft to LoadOut support.',
              ),
              onTap: _openSupportEmail,
            ),
            ListTile(
              leading: const Icon(Icons.restore_outlined),
              title: const Text('Restore from backup'),
              subtitle: const Text(
                'Open Backup & Export to restore an encrypted backup.',
              ),
              onTap: _openBackupScreen,
            ),
            ListTile(
              leading: const Icon(Icons.workspace_premium_outlined),
              title: const Text('Restore purchases'),
              subtitle: const Text(
                'If you bought Pro on another device or after reinstalling, '
                'restore it here.',
              ),
              onTap: _restorePurchases,
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Privacy Policy'),
              onTap: _openPrivacy,
            ),
            ListTile(
              leading: const Icon(Icons.gavel_outlined),
              title: const Text('Terms & Safety Disclaimer'),
              onTap: _openDisclaimer,
            ),
            ListTile(
              leading: Icon(
                Icons.delete_forever_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Delete my data',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              subtitle: const Text(
                'Erase all loads, firearms, batches, brass lots, and '
                'ballistic profiles on this device.',
              ),
              onTap: _confirmDeleteData,
            ),
            const SizedBox(height: 24),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'LoadOut v$_appVersion',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────── support / recovery actions ───────────────

  Future<void> _openSupportEmail() async {
    final platform = defaultTargetPlatform.name;
    final user = FirebaseAuth.instance.currentUser;
    final accountState = user == null
        ? 'signed out'
        : user.isAnonymous
            ? 'guest'
            : 'signed in';
    final body = Uri.encodeComponent(
      'Describe the issue here.\n\n'
      '— — —\n'
      'App: LoadOut v$_appVersion\n'
      'Platform: $platform\n'
      'Account: $accountState\n',
    );
    final subject = Uri.encodeComponent('LoadOut Support');
    final uri = Uri.parse('mailto:$_supportEmail?subject=$subject&body=$body');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No email app available — write to $_supportEmail.',
          ),
        ),
      );
    }
  }

  void _openBackupScreen() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const BackupScreen()),
    );
  }

  void _openPrivacy() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PrivacyScreen()),
    );
  }

  void _openDisclaimer() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DisclaimerScreen(
          onAccept: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  Future<void> _restorePurchases() async {
    final purchases = context.read<PurchasesService>();
    final entitlement = context.read<EntitlementNotifier>();
    final messenger = ScaffoldMessenger.of(context);
    if (!purchases.isConfigured) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Pro is not yet available.')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final info = await purchases.restorePurchases();
      await entitlement.refresh();
      final isPro = PurchasesService.isProEntitled(info);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            isPro
                ? 'Pro restored.'
                : 'No purchases found on this account.',
          ),
        ),
      );
    } on PlatformException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Restore failed: ${e.message ?? e.code}')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Restore failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ─────────────── delete my data flow ───────────────

  /// Step 1 of the triple-confirm. Shows a bottom sheet that explains
  /// what gets deleted, with a checkbox the user has to tick before the
  /// final destructive button is enabled.
  Future<void> _confirmDeleteData() async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => const _DeleteDataSheet(),
    );
    if (confirmed != true || !mounted) return;
    await _runDeleteData();
  }

  Future<void> _runDeleteData() async {
    final db = context.read<AppDatabase>();
    final auth = context.read<AuthService>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await db.wipeUserData();
      try {
        await auth.signOut();
      } catch (_) {
        // Already signed out, anonymous user, etc. — proceed.
      }
      if (!mounted) return;
      // Pop back to the home shell. _AuthGate will rebuild against the
      // null user and route to LoginScreen automatically.
      Navigator.of(context).popUntil((r) => r.isFirst);
      messenger.showSnackBar(
        const SnackBar(content: Text('Your data has been deleted.')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// The triple-confirm bottom sheet for "Delete my data". The first
/// surface is the section tile tap; this sheet is the second; the
/// red final button is the third.
class _DeleteDataSheet extends StatefulWidget {
  const _DeleteDataSheet();

  @override
  State<_DeleteDataSheet> createState() => _DeleteDataSheetState();
}

class _DeleteDataSheetState extends State<_DeleteDataSheet> {
  bool _understood = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.warning_amber_outlined,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Text(
                  'Delete my data',
                  style: theme.textTheme.titleLarge,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              "This will erase all your loads, firearms, batches, brass "
              'lots, and ballistic profiles on this device. Cloud backups '
              'stay (you can restore later).',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _understood,
              onChanged: (v) => setState(() => _understood = v ?? false),
              title: const Text("I understand this can't be undone."),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                onPressed: _understood
                    ? () => Navigator.of(context).pop(true)
                    : null,
                icon: const Icon(Icons.delete_forever),
                label: const Text('Delete everything.'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
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
