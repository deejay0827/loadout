// FILE: lib/screens/settings/privacy_data_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Settings → Privacy & Data submenu. Brings together every action that
// affects what gets stored, sent off-device, or wiped:
//
//   * Crashlytics opt-in toggle
//   * Export my data (JSON local export)
//   * Delete my data (triple-confirm wipe)
//   * Privacy Policy link
//   * Terms of Service link
//   * Re-read safety disclaimer
//
// Cloud Backup / Cloud Sync live on their own dedicated screens (linked
// from the top-level Settings page), so this submenu is the audit /
// destructive surface — not a duplicate of those flows.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Privacy is a brand promise (CLAUDE.md §13) and reviewers expect a
// single screen they can point to when verifying app-store privacy
// disclosures. Co-locating Crashlytics opt-in + export + delete +
// links to legal documents makes that audit trivial.

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../database/database.dart';
import '../../main.dart'
    show kCrashlyticsEnabledDefault, kCrashlyticsEnabledPrefKey;
import '../../services/auth_service.dart';
import '../backup/backup_screen.dart';
import '../disclaimer/disclaimer_screen.dart';
import '../legal/terms_screen.dart';
import '../privacy/privacy_screen.dart';

class PrivacyDataScreen extends StatefulWidget {
  const PrivacyDataScreen({super.key});

  @override
  State<PrivacyDataScreen> createState() => _PrivacyDataScreenState();
}

class _PrivacyDataScreenState extends State<PrivacyDataScreen> {
  bool _busy = false;
  // Mirror the same default the boot path uses so the toggle's initial
  // state matches what `_configureCrashlytics` will actually set —
  // otherwise a fresh-install user sees the switch off while
  // collection is on.
  bool _crashlyticsEnabled = kCrashlyticsEnabledDefault;
  bool _crashlyticsLoaded = false;

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _loadCrashlyticsPref();
  }

  Future<void> _loadCrashlyticsPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _crashlyticsEnabled = prefs.getBool(kCrashlyticsEnabledPrefKey) ??
            kCrashlyticsEnabledDefault;
        _crashlyticsLoaded = true;
      });
    } catch (_) {
      // Disk read failure — fall back to the documented default so the
      // toggle still reflects the actual collection state.
      if (mounted) setState(() => _crashlyticsLoaded = true);
    }
  }

  Future<void> _setCrashlyticsEnabled(bool value) async {
    setState(() => _crashlyticsEnabled = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kCrashlyticsEnabledPrefKey, value);
    } catch (e) {
      debugPrint('PrivacyData: persist Crashlytics opt-in: $e');
    }
    try {
      await FirebaseCrashlytics.instance
          .setCrashlyticsCollectionEnabled(value);
    } catch (e) {
      debugPrint('PrivacyData: update Crashlytics state: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & Data')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.bug_report_outlined),
              title: const Text('Send anonymous crash reports'),
              subtitle: const Text(
                'Helps us catch bugs faster. No personal data, '
                'recipes, or firearms info is included.',
              ),
              value: _crashlyticsEnabled,
              onChanged: _crashlyticsLoaded
                  ? (v) {
                      // ignore: discarded_futures
                      _setCrashlyticsEnabled(v);
                    }
                  : null,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Export my data (JSON)'),
              subtitle: const Text(
                'Save a local JSON of every load, firearm, batch, and '
                'brass lot on this device. Stored to your Files / '
                'Downloads — never uploaded.',
              ),
              onTap: _openBackupScreen,
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Privacy Policy'),
              onTap: _openPrivacy,
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Terms of Service'),
              onTap: _openTerms,
            ),
            ListTile(
              leading: const Icon(Icons.gavel_outlined),
              title: const Text('Re-read safety disclaimer'),
              subtitle: const Text(
                'Reloading is dangerous. Read the warning again any time.',
              ),
              onTap: _openDisclaimer,
            ),
            const Divider(height: 1),
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
          ],
        ),
      ),
    );
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

  void _openTerms() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TermsScreen()),
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

  /// Triple-confirm flow. The settings tile is the first surface; the
  /// bottom sheet is the second; the red destructive button is the
  /// third.
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
      // Pop everything; _AuthGate routes back to LoginScreen on signout.
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
