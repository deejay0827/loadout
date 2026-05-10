// FILE: lib/screens/settings/help_support_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Settings → Help & Support submenu. Surfaces the actions that are about
// "I need help with this app" rather than "I want to change a setting":
//
//   * Email support (mailto: with app version + platform pre-filled)
//   * Print a sample notebook page (prints a blank reloading log to take
//     to the bench, scan back in later via Photo Import)
//   * Restore from backup (opens BackupScreen)
//   * About / version row
//
// Each action is a verbatim move from the old flat Settings screen so
// the user's muscle memory still finds these.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/sample_notebook_service.dart';
import '../../services/support.dart';
import '../backup/backup_screen.dart';

class HelpSupportScreen extends StatefulWidget {
  const HelpSupportScreen({super.key});

  @override
  State<HelpSupportScreen> createState() => _HelpSupportScreenState();
}

class _HelpSupportScreenState extends State<HelpSupportScreen> {
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _loadAppVersion();
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
      // simply won't show a version.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Help & Support')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.mail_outline),
            title: const Text('Email Support'),
            subtitle: const Text(
              'Open your mail app with a draft to LoadOut support.',
            ),
            onTap: _openSupportEmail,
          ),
          ListTile(
            leading: const Icon(Icons.print_outlined),
            title: const Text('Print a Sample Notebook Page'),
            subtitle: const Text(
              'A blank reloading log page you can print at home, fill in '
              'by hand, then photo-import back into LoadOut.',
            ),
            onTap: _shareSampleNotebook,
          ),
          ListTile(
            leading: const Icon(Icons.restore_outlined),
            title: const Text('Restore from Backup'),
            subtitle: const Text(
              'Open Backup & Export to restore an encrypted backup.',
            ),
            onTap: _openBackupScreen,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            subtitle: Text(
              _appVersion.isEmpty ? 'LoadOut' : 'LoadOut v$_appVersion',
            ),
            onTap: () {},
          ),
        ],
      ),
    );
  }

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
          content: Text('No email app available — write to $supportEmail.'),
        ),
      );
    }
  }

  Future<void> _shareSampleNotebook() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await const SampleNotebookService().share(context);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not generate notebook page: $e')),
      );
    }
  }

  void _openBackupScreen() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const BackupScreen()),
    );
  }
}
