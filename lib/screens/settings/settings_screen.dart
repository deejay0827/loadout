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
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:package_info_plus/package_info_plus.dart';

import '../../database/database.dart';
import '../../l10n/app_localizations.dart';
import '../../main.dart' show kCrashlyticsEnabledPrefKey;
import '../../services/auth_service.dart';
import '../../services/auto_save_service.dart';
import '../../services/beginner_mode_service.dart';
import '../../services/entitlement_notifier.dart';
import '../../services/locale_service.dart';
import '../../services/purchases_service.dart';
import '../../services/support.dart';
import '../../services/unit_service.dart';
import '../backup/backup_screen.dart';
import '../devices/devices_screen.dart';
import '../disclaimer/disclaimer_screen.dart';
import '../legal/terms_screen.dart';
import '../privacy/privacy_screen.dart';
import '../sync/cloud_sync_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;

  /// Populated from `package_info_plus` in [initState]. Falls back to
  /// the empty string until the future resolves so the footer keeps the
  /// "LoadOut v…" prefix without a trailing literal.
  String _appVersion = '';

  /// Mirrors the `crashlytics_enabled` SharedPreferences flag. Defaults
  /// to false (collection OFF) until the disk read returns. The
  /// SwitchListTile is built against this value so the user sees the
  /// real state rather than a flicker on first frame.
  bool _crashlyticsEnabled = false;

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _loadAppVersion();
    // ignore: discarded_futures
    _loadCrashlyticsPref();
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _appVersion = '${info.version}+${info.buildNumber}';
      });
    } catch (_) {
      // PackageInfo may fail on edge platforms / tests; the footer
      // simply won't show a version. Not a fatal condition.
    }
  }

  Future<void> _loadCrashlyticsPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _crashlyticsEnabled =
            prefs.getBool(kCrashlyticsEnabledPrefKey) ?? false;
      });
    } catch (_) {
      // Fail closed — leave the toggle in its default OFF state.
    }
  }

  /// Persist the new opt-in choice and immediately propagate it to the
  /// running Crashlytics instance so the user doesn't have to relaunch
  /// to take effect. The global `FlutterError.onError` /
  /// `PlatformDispatcher.instance.onError` handlers wired in
  /// `lib/main.dart` are NOT installed mid-session here — that
  /// requires a relaunch. We do still flip
  /// `setCrashlyticsCollectionEnabled` so any native-side queueing the
  /// plugin does is gated immediately.
  Future<void> _setCrashlyticsEnabled(bool value) async {
    setState(() => _crashlyticsEnabled = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kCrashlyticsEnabledPrefKey, value);
    } catch (e) {
      debugPrint('Settings: could not persist Crashlytics opt-in: $e');
    }
    try {
      await FirebaseCrashlytics.instance
          .setCrashlyticsCollectionEnabled(value);
    } catch (e) {
      debugPrint(
        'Settings: could not update Crashlytics collection state: $e',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<AutoSaveService>();
    final beginner = context.watch<BeginnerModeService>();
    final units = context.watch<UnitService>();
    final localeService = context.watch<LocaleService>();
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          children: [
            const _SectionHeader('Units of Measurement'),
            _UnitsSection(units: units),
            const _SectionHeader('Experience'),
            SwitchListTile(
              secondary: const Icon(Icons.school_outlined),
              title: const Text('Beginner Mode'),
              subtitle: const Text(
                'Keeps the recipe form simple, shows extra hints, and '
                'starts you in the Quick Add screen. Turn off when you '
                'want every field at your fingertips.',
              ),
              value: beginner.isEnabled,
              onChanged: (v) {
                // ignore: discarded_futures
                beginner.setEnabled(v);
              },
            ),
            // Language picker. Renders the user's chosen language as
            // the trailing label and opens a bottom sheet listing every
            // supported locale + the "System default" option. The
            // dropdown re-resolves AppLocalizations on selection so
            // every visible string flips immediately, including this
            // tile.
            _LanguageTile(
              localeService: localeService,
              title: l.settingsLanguage,
              subtitle: l.settingsLanguageSubtitle,
              systemDefaultLabel: l.settingsLanguageSystem,
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
            const _SectionHeader('Devices'),
            ListTile(
              leading: const Icon(Icons.bluetooth_outlined),
              title: const Text('Connected Devices'),
              subtitle: const Text(
                'Pair a Bluetooth chronograph or Kestrel weather meter.',
              ),
              onTap: _openDevices,
            ),
            const _SectionHeader('Diagnostics'),
            SwitchListTile(
              secondary: const Icon(Icons.bug_report_outlined),
              title: const Text('Send anonymous crash reports'),
              subtitle: const Text(
                'Helps us catch bugs faster. No personal data, '
                'recipes, or firearms info is included.',
              ),
              value: _crashlyticsEnabled,
              onChanged: (v) {
                // ignore: discarded_futures
                _setCrashlyticsEnabled(v);
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
              leading: const Icon(Icons.cloud_sync_outlined),
              title: const Text('Cloud Sync (Pro)'),
              subtitle: const Text(
                'Continuously sync your data to your own iCloud, '
                'Google Drive, or OneDrive. End-to-end encrypted.',
              ),
              onTap: _openCloudSync,
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
                  _appVersion.isEmpty
                      ? 'LoadOut'
                      : 'LoadOut v$_appVersion',
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
    final uri = Uri.parse('mailto:$supportEmail?subject=$subject&body=$body');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No email app available — write to $supportEmail.',
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

  void _openCloudSync() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CloudSyncScreen()),
    );
  }

  void _openDevices() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DevicesScreen()),
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

/// Renders the master Imperial / Metric switch + a per-category list,
/// modeled on the Strelok / Ballistics Calculator units page.
///
/// The master switch sets every category at once. The per-category
/// segmented buttons let advanced users mix systems (e.g. metric for
/// range but imperial for bullet weight). Changing the master switch
/// resets all per-category overrides.
class _UnitsSection extends StatelessWidget {
  const _UnitsSection({required this.units});

  final UnitService units;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Master switch.
          SegmentedButton<UnitSystem>(
            segments: const [
              ButtonSegment(
                value: UnitSystem.imperial,
                label: Text('Use Imperial'),
              ),
              ButtonSegment(
                value: UnitSystem.metric,
                label: Text('Use Metric'),
              ),
            ],
            selected: {units.system},
            onSelectionChanged: (s) {
              // ignore: discarded_futures
              units.setSystem(s.first);
            },
            showSelectedIcon: false,
          ),
          const SizedBox(height: 8),
          Text(
            'Pick your default. You can fine-tune individual measurements below.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          for (final cat in UnitCategory.values) ...[
            _UnitCategoryRow(units: units, category: cat),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// One row inside the Units section: the category title on top, a
/// horizontally-scrolling segmented button below.
class _UnitCategoryRow extends StatelessWidget {
  const _UnitCategoryRow({required this.units, required this.category});

  final UnitService units;
  final UnitCategory category;

  @override
  Widget build(BuildContext context) {
    final options = kUnitOptions[category] ?? const <String>[];
    final current = units.unitFor(category);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          unitCategoryLabel(category),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
        ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<String>(
            segments: [
              for (final u in options)
                ButtonSegment(value: u, label: Text(unitDisplayLabel(u))),
            ],
            selected: {current},
            onSelectionChanged: (s) {
              // ignore: discarded_futures
              units.setOverride(category, s.first);
            },
            showSelectedIcon: false,
          ),
        ),
      ],
    );
  }
}

/// Settings list-tile that opens a bottom-sheet picker for the UI
/// language. The tile's trailing label reflects the current selection
/// (or "System default" when no override is set). Tapping it opens
/// `_LanguagePickerSheet` which lists every supported locale plus the
/// system-default option, each labeled in its OWN language so a user
/// who can't read the current UI can still find their language.
class _LanguageTile extends StatelessWidget {
  const _LanguageTile({
    required this.localeService,
    required this.title,
    required this.subtitle,
    required this.systemDefaultLabel,
  });

  final LocaleService localeService;
  final String title;
  final String subtitle;
  final String systemDefaultLabel;

  @override
  Widget build(BuildContext context) {
    final code = localeService.languageCode;
    final currentLabel = code == null
        ? systemDefaultLabel
        : kLanguageDisplayNames[code] ?? code;
    return ListTile(
      leading: const Icon(Icons.language_outlined),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Text(
        currentLabel,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
      onTap: () => _openPicker(context),
    );
  }

  Future<void> _openPicker(BuildContext context) async {
    final selected = await showModalBottomSheet<_LanguagePickerResult>(
      context: context,
      builder: (ctx) => _LanguagePickerSheet(
        currentCode: localeService.languageCode,
        systemDefaultLabel: systemDefaultLabel,
      ),
    );
    if (selected == null) return;
    // ignore: discarded_futures
    localeService.setLanguageCode(selected.code);
  }
}

/// Bottom-sheet picker — one row per supported locale, plus "System
/// default" at the top. Returning `null` means the user dismissed
/// without picking; otherwise a `_LanguagePickerResult` with the
/// chosen language tag (or `null` for the system-default row).
class _LanguagePickerSheet extends StatelessWidget {
  const _LanguagePickerSheet({
    required this.currentCode,
    required this.systemDefaultLabel,
  });

  final String? currentCode;
  final String systemDefaultLabel;

  @override
  Widget build(BuildContext context) {
    // Each row is a plain ListTile with a manual check icon for the
    // currently-selected entry. Avoids the `RadioListTile.groupValue` /
    // `onChanged` deprecation introduced in Flutter 3.32+ (which wants
    // a `RadioGroup` ancestor) without the boilerplate of wrapping the
    // whole sheet in one.
    final rows = <_LanguagePickerRowData>[
      _LanguagePickerRowData(code: null, label: systemDefaultLabel),
      for (final code in kSupportedLanguageCodes)
        _LanguagePickerRowData(
          code: code,
          label: kLanguageDisplayNames[code] ?? code,
        ),
    ];
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final row in rows)
            ListTile(
              leading: Icon(
                row.code == currentCode
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: row.code == currentCode
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: Text(row.label),
              onTap: () => Navigator.of(context).pop(
                _LanguagePickerResult(row.code),
              ),
            ),
        ],
      ),
    );
  }
}

/// Row metadata for a single entry in [_LanguagePickerSheet]. `code:
/// null` is the "System default" row.
class _LanguagePickerRowData {
  const _LanguagePickerRowData({required this.code, required this.label});
  final String? code;
  final String label;
}

/// Tiny result wrapper so we can distinguish "the user picked the
/// system-default row" (returns `_LanguagePickerResult(null)`) from
/// "the user dismissed the sheet" (returns `null` from
/// showModalBottomSheet).
class _LanguagePickerResult {
  const _LanguagePickerResult(this.code);
  final String? code;
}
