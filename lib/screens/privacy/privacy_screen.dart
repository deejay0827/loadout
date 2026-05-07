import 'package:flutter/material.dart';

/// Full-text privacy policy. Reachable from the privacy dialog on the home
/// screen. Mirrors `PRIVACY_POLICY.md` in the repo root — keep them in sync.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  static const String _effectiveDate = '2026-05-07';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final mutedColor = theme.colorScheme.onSurfaceVariant;

    final headingStyle = textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w600,
    );
    final subheadingStyle = textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );
    final bodyStyle = textTheme.bodyMedium;
    final mutedBodyStyle = bodyStyle?.copyWith(color: mutedColor);

    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Policy')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('LoadOut Privacy Policy', style: textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            'Effective date: $_effectiveDate',
            style: mutedBodyStyle,
          ),
          const SizedBox(height: 24),

          Text('What this app is', style: headingStyle),
          const SizedBox(height: 8),
          Text(
            'LoadOut is a reloading reference and tracking app. It helps you '
            'record your recipes, firearms, and components. Reference '
            'catalogs (cartridges, powders, bullets, primers, brass, '
            'firearms, parts) ship with the app for browsing.',
            style: bodyStyle,
          ),
          const SizedBox(height: 24),

          Text('The short version', style: headingStyle),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'We don\'t track you. No analytics. No advertising. No '
                  'third-party data sharing.',
              'We don\'t run a backend that stores your reloading data. '
                  'Your recipes, firearms, custom components, and inventory '
                  'live on your device.',
              'The only thing we send to a server is what\'s needed for '
                  'sign-in (your email, an OAuth token, etc.) — and that '
                  'goes to Firebase Authentication, not to us.',
              'If you opt in to cloud backup (a Pro feature), your data is '
                  'encrypted on your device with a passphrase only you know, '
                  'and uploaded to your own iCloud Drive or Google Drive. '
                  'LoadOut never receives the encrypted blob.',
            ],
          ),
          const SizedBox(height: 24),

          Text('Data we store on your device', style: headingStyle),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'Recipes, custom components you add, firearms you\'ve added, '
                  'and shots-fired counts.',
              'This data lives in an on-device SQLite database (in your '
                  'app\'s private storage).',
              'The only ways this data is removed are if you delete the app, '
                  'reset your device, clear app storage, or use the in-app '
                  'delete actions.',
            ],
          ),
          const SizedBox(height: 24),

          Text('Data we send to a server', style: headingStyle),
          const SizedBox(height: 8),
          Text(
            'We use Firebase Authentication (Google Cloud) for sign-in. The '
            'following data is processed by Firebase Authentication on '
            'Google\'s servers:',
            style: bodyStyle,
          ),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'Your email address.',
              'A password hash (if you use email/password sign-in) — stored '
                  'by Firebase, not by us; we never see the plaintext.',
              'OAuth tokens for any third-party providers you use (Google, '
                  'Apple, Microsoft, Yahoo).',
              'Firebase\'s own technical metadata (anonymous user IDs, '
                  'timestamps of sign-ins).',
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'We do not see, store, or transmit any of your reloading data — '
            'recipes, firearms, components, or inventory. LoadOut does not '
            'operate any backend that receives or stores reloading data.',
            style: bodyStyle,
          ),
          const SizedBox(height: 24),

          Text('Backups & exports', style: headingStyle),
          const SizedBox(height: 8),
          Text(
            'You have two ways to get your data off your device. Both are '
            'designed so that LoadOut never sees the contents of your '
            'reloading data.',
            style: bodyStyle,
          ),
          const SizedBox(height: 16),
          Text('Local export (free)', style: subheadingStyle),
          const SizedBox(height: 8),
          Text(
            'You can export your full reloading database to a JSON file '
            'using the in-app export action. The file is written to your '
            'device\'s Files / Downloads area. From there you control where '
            'it goes — you can keep it locally, AirDrop it, email it, or '
            'copy it to any storage you choose.',
            style: bodyStyle,
          ),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'The export is a plain JSON file. You are responsible for '
                  'protecting it if you store it somewhere unencrypted.',
              'LoadOut servers are not involved. The file never touches our '
                  'infrastructure.',
            ],
          ),
          const SizedBox(height: 16),
          Text('Cloud backup (Pro, opt-in)', style: subheadingStyle),
          const SizedBox(height: 8),
          Text(
            'If you have LoadOut Pro and choose to enable cloud backup, the '
            'app will:',
            style: bodyStyle,
          ),
          const SizedBox(height: 8),
          _NumberedList(
            style: bodyStyle,
            items: const [
              'Ask you to set a passphrase. This passphrase is used to '
                  'encrypt your backup on your device, before any upload '
                  'happens.',
              'Upload the encrypted backup to your own cloud account — '
                  'iCloud Drive on iOS, Google Drive on Android (or iOS, if '
                  'you prefer). You sign in to your cloud provider '
                  'directly; LoadOut does not handle your cloud credentials.',
              'Store nothing on LoadOut servers. There is no LoadOut backend '
                  'involved in cloud backup. The encrypted blob is between '
                  'your device and your cloud provider.',
            ],
          ),
          const SizedBox(height: 12),
          Text('What this means in practice:', style: bodyStyle),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'Your passphrase never leaves your device. We can\'t read '
                  'your backup, and neither can your cloud provider.',
              'We can\'t recover a lost passphrase. If you forget it, the '
                  'backup is unrecoverable. Write it down somewhere safe.',
              'Your cloud provider\'s privacy policy applies to the '
                  'encrypted blob while it\'s stored in your iCloud Drive '
                  'or Google Drive. Apple and Google see an opaque '
                  'encrypted file; they do not see your reloading data.',
              'Cloud backup is opt-in. If you don\'t enable it, nothing '
                  'about your reloading data leaves your device.',
            ],
          ),
          const SizedBox(height: 24),

          Text('What we don\'t do', style: headingStyle),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'No analytics. We don\'t track your in-app behavior.',
              'No advertising. The app shows no ads.',
              'No third-party data sharing or selling.',
              'No location collection.',
              'No microphone or camera access (the app doesn\'t request '
                  'these).',
              'No contacts, photos, or other personal device data is '
                  'collected.',
              'No LoadOut-operated cloud storage of your reloading data — '
                  'ever.',
            ],
          ),
          const SizedBox(height: 24),

          Text('Sign-in providers', style: headingStyle),
          const SizedBox(height: 8),
          Text(
            'If you sign in with a third-party provider (Google, Apple, '
            'Microsoft, Yahoo), that provider\'s privacy policy also '
            'applies to your relationship with them. We only request the '
            'minimum scope needed to identify you (typically email and '
            'name).',
            style: bodyStyle,
          ),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'Google: https://policies.google.com/privacy',
              'Apple: https://www.apple.com/legal/privacy/',
              'Microsoft: https://privacy.microsoft.com/privacystatement',
              'Yahoo: https://legal.yahoo.com/us/en/yahoo/privacy/',
            ],
          ),
          const SizedBox(height: 24),

          Text('Children', style: headingStyle),
          const SizedBox(height: 8),
          Text(
            'LoadOut is not directed at children under 13 (or 17, given '
            'the subject matter). We do not knowingly collect data from '
            'minors. Reloading is for adults — see the app\'s disclaimer.',
            style: bodyStyle,
          ),
          const SizedBox(height: 24),

          Text('Your rights', style: headingStyle),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'Delete your account: sign out and delete the app. To remove '
                  'your auth record from Firebase, request account deletion '
                  'via the contact below.',
              'Export your data: use the in-app local export to get a JSON '
                  'copy of your reloading database. This is free for all '
                  'users.',
              'EU/UK/CA residents (GDPR / UK GDPR / CCPA): you have rights '
                  'to access, correct, delete, and port your data. Contact '
                  'us using the address below.',
            ],
          ),
          const SizedBox(height: 24),

          Text('Changes to this policy', style: headingStyle),
          const SizedBox(height: 8),
          Text(
            'We will update the effective date and notify you in-app (via '
            'a re-prompt of the disclaimer / privacy dialog) if we make '
            'material changes.',
            style: bodyStyle,
          ),
          const SizedBox(height: 24),

          Text('Contact', style: headingStyle),
          const SizedBox(height: 8),
          Text('Johnson Digital Systems', style: bodyStyle),
          Text('info@johnsondigitalsystems.com', style: bodyStyle),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

/// Renders a list of strings as `• `-prefixed lines. Each item is its own
/// `Text` so long items wrap correctly under the bullet.
class _BulletList extends StatelessWidget {
  const _BulletList({required this.items, required this.style});

  final List<String> items;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: style),
                Expanded(child: Text(item, style: style)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Renders a list of strings as `1. `-prefixed lines. Each item is its own
/// `Text` so long items wrap correctly under the number.
class _NumberedList extends StatelessWidget {
  const _NumberedList({required this.items, required this.style});

  final List<String> items;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${i + 1}.  ', style: style),
                Expanded(child: Text(items[i], style: style)),
              ],
            ),
          ),
      ],
    );
  }
}
