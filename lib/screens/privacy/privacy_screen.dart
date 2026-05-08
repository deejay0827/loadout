// FILE: lib/screens/privacy/privacy_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Renders the in-app privacy policy as a scrollable text screen. Mirrors
// the hosted policy at `public/legal/privacy.html` — keep them in sync. The
// screen has no input or interactive state — just headings, paragraphs,
// and bullet lists.
//
// The policy was last revised on 2026-05-07 to add explicit coverage of
// RevenueCat (in-app purchase verification), the optional opt-in
// Crashlytics future surface, the four device permissions LoadOut asks
// for (camera, photos, location-when-in-use, Bluetooth), an enumerated
// data-retention section, and an enumerated GDPR/CCPA rights section. A
// "Draft — review with counsel before publication" banner sits at the
// top so anyone reading this in a build before legal review knows what
// they're looking at. Remove the banner once counsel signs off.
//
// Page sections, in order:
//
//   - Title + effective date + draft banner
//   - "What this app is" — one paragraph orienting the reader
//   - "The short version" — TL;DR bullets
//   - "What we collect"
//       * Account & authentication (Firebase Authentication)
//       * In-app purchases (RevenueCat)
//       * Diagnostics (optional, opt-in — future release)
//       * Data we download (one-way catalog updates)
//   - "What we don't collect" — explicit negatives
//   - "Device permissions" — when the app prompts for each
//   - "Backups & exports" — local export (free) + opt-in cloud backup (Pro)
//   - "Sub-processors and third parties"
//   - "How long we keep data"
//   - "How to delete your data" — Settings → Delete my data, account deletion
//   - "Your privacy rights" — GDPR / CCPA / other US states
//   - "Children" — 18+
//   - "International data transfers" — SCCs etc.
//   - "Security"
//   - "Changes to this policy"
//   - "Contact" — support@johnsondigital.com
//
// `_BulletList` lays out a list of strings as `•`-prefixed rows so long
// items wrap correctly under the marker.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// LoadOut's marketing positioning rests on the claim that user reloading
// data never leaves the device unless the user opts in to cloud backup.
// That promise has to be reinforced consistently in the App Store /
// Play Store privacy disclosures, the hosted privacy page, and this
// screen. This file is the user-facing surface of that policy and is
// reachable from the home privacy dialog and from Settings.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/screens/home/home_screen.dart — the privacy dialog's "Read the
//   full policy" link pushes this screen.
// - lib/screens/settings/settings_screen.dart — "Privacy Policy" tile.
// - lib/screens/how_it_works/how_it_works_screen.dart — the
//   "Local-First & Privacy" topic CTA pushes this screen.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None — pure rendering of `const` strings. No I/O, no network, no
// plugin calls.

import 'package:flutter/material.dart';

/// Full-text privacy policy. Reachable from the privacy dialog on the home
/// screen and Settings. Mirrors `public/legal/privacy.html` — keep them
/// in sync.
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
          const SizedBox(height: 16),
          _DraftBanner(theme: theme),
          const SizedBox(height: 24),

          Text('What this app is', style: headingStyle),
          const SizedBox(height: 8),
          Text(
            'LoadOut is a local-first reloading reference and tracking app '
            'for iOS and Android. It helps you record your loads, firearms, '
            'and components, and read SAAMI cartridge specifications. '
            'Reference catalogs ship with the app for browsing offline.',
            style: bodyStyle,
          ),
          const SizedBox(height: 24),

          Text('The short version', style: headingStyle),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'We don\'t track you. No analytics. No advertising. No selling '
                  'of your data.',
              'Your reloading data — loads, firearms, components, batches, '
                  'brass lots, ballistic profiles — lives on your device. We '
                  'don\'t run a server that stores it.',
              'The only thing we send to our service providers is what\'s '
                  'needed for sign-in (email, OAuth tokens) and for '
                  'processing in-app purchases (anonymous purchase records).',
              'If you opt in to cloud backup (a Pro feature), your data is '
                  'encrypted on your device with a passphrase only you know, '
                  'and uploaded to your own iCloud Drive or Google Drive. We '
                  'never receive the encrypted blob.',
            ],
          ),
          const SizedBox(height: 24),

          Text('What we collect', style: headingStyle),
          const SizedBox(height: 12),

          Text(
            'Account & authentication (Firebase Authentication)',
            style: subheadingStyle,
          ),
          const SizedBox(height: 8),
          Text(
            'We use Firebase Authentication (Google Cloud) to identify you '
            'and let you sign in across devices. Firebase stores, on '
            'Google\'s servers:',
            style: bodyStyle,
          ),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'Your email address.',
              'A Firebase-assigned anonymous user ID (UID).',
              'A password hash, if you use email/password sign-in. We never '
                  'see the plaintext.',
              'OAuth tokens for any third-party providers you use (Google, '
                  'Apple, Microsoft, Yahoo).',
              'Sign-in metadata (timestamps, last sign-in IP) maintained by '
                  'Firebase.',
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'We use this data only to authenticate you, not for marketing or '
            'analytics.',
            style: bodyStyle,
          ),
          const SizedBox(height: 16),

          Text(
            'In-app purchases (RevenueCat)',
            style: subheadingStyle,
          ),
          const SizedBox(height: 8),
          Text(
            'If you buy LoadOut Pro, the App Store or Google Play processes '
            'the transaction. We use RevenueCat to verify your purchase and '
            'unlock Pro features across devices. RevenueCat receives:',
            style: bodyStyle,
          ),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'Your Firebase UID (so your purchase follows your account).',
              'The store-level transaction record (product ID, purchase '
                  'date, expiration if applicable).',
              'Anonymous device and platform metadata RevenueCat needs to '
                  'validate receipts.',
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'RevenueCat does not receive your email address or any '
            'reloading data.',
            style: bodyStyle,
          ),
          const SizedBox(height: 16),

          Text(
            'Diagnostics (Firebase Crashlytics — opt-in)',
            style: subheadingStyle,
          ),
          const SizedBox(height: 8),
          Text(
            'LoadOut includes Firebase Crashlytics to record crash and '
            'error reports. Collection is off by default. You can turn '
            'it on at any time from Settings → Send crash reports.',
            style: bodyStyle,
          ),
          const SizedBox(height: 8),
          Text(
            'When you opt in, crash reports include:',
            style: bodyStyle,
          ),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'Technical metadata Crashlytics needs to diagnose the '
                  'crash (device model, OS version, app version, stack '
                  'traces, Firebase UID).',
              'Non-fatal errors the app catches and reports for '
                  'diagnostic purposes.',
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Crash reports do not include your reloading data or any '
            'user-typed text. If you turn the toggle off again, '
            'collection stops immediately.',
            style: bodyStyle,
          ),
          const SizedBox(height: 16),

          Text(
            'Data we download (read-only catalog updates)',
            style: subheadingStyle,
          ),
          const SizedBox(height: 8),
          Text(
            'When the app starts, it makes a one-way read request to '
            'Firebase Storage to check whether the bundled reference '
            'catalog has been corrected or expanded since the version you '
            'installed. If a newer catalog is available, we download and '
            'cache it on your device. We do not upload anything about you, '
            'your device, or your reloading data when this check runs. The '
            'catalog files are identical for every user.',
            style: bodyStyle,
          ),
          const SizedBox(height: 24),

          Text('What we don\'t collect', style: headingStyle),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'Reloading data. Your loads, firearms, custom components, '
                  'batches, brass lots, ballistic profiles, and shots-fired '
                  'counts stay in the on-device SQLite database.',
              'Photos. The photo-import feature reads images on-device so '
                  'you can scan handwritten reloading notes. Images and '
                  'parsed text never leave your device.',
              'Location. We use your location only when you tap "Get '
                  'current weather" inside the app. Your coordinates are '
                  'sent to the weather provider for that single request '
                  'and are not stored by us.',
              'Microphone. The app does not request microphone access.',
              'Bluetooth identifiers. Bluetooth is used only when you pair '
                  'a chronograph (Garmin Xero) or weather meter (Kestrel). '
                  'The pairing and the data they send are local to your '
                  'device.',
              'Contacts, calendar, health, advertising IDs, browsing '
                  'history. The app does not request any of these.',
            ],
          ),
          const SizedBox(height: 24),

          Text('Device permissions', style: headingStyle),
          const SizedBox(height: 8),
          Text(
            'LoadOut asks for the following device permissions only when '
            'you use the relevant feature. You can decline any of them and '
            'continue using the rest of the app.',
            style: bodyStyle,
          ),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'Camera — to photograph handwritten reloading notes for the '
                  'photo-import feature. The image stays on-device.',
              'Photo library — to choose an existing photo of reloading '
                  'notes to import. The image stays on-device.',
              'Location (when in use) — to fetch current weather for '
                  'ballistics calculations when you tap "Get current '
                  'weather". Your coordinates are sent only to the weather '
                  'provider for that request.',
              'Bluetooth — to pair with a chronograph or weather meter. '
                  'The connection is local to your device.',
            ],
          ),
          const SizedBox(height: 24),

          Text('Backups & exports', style: headingStyle),
          const SizedBox(height: 8),
          Text(
            'You have two ways to get your data off your device. Both are '
            'designed so we never see the contents.',
            style: bodyStyle,
          ),
          const SizedBox(height: 16),
          Text('Local export (free)', style: subheadingStyle),
          const SizedBox(height: 8),
          Text(
            'You can export your full reloading database to a JSON file '
            'using the in-app export action. The file is written to your '
            'device\'s Files / Downloads area and from there you control '
            'where it goes. Our infrastructure is not involved.',
            style: bodyStyle,
          ),
          const SizedBox(height: 16),
          Text(
            'End-to-end encrypted cloud backup (Pro, opt-in)',
            style: subheadingStyle,
          ),
          const SizedBox(height: 8),
          Text(
            'If you have LoadOut Pro and you turn on cloud backup, the app:',
            style: bodyStyle,
          ),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'Asks you to set a passphrase. Your data is encrypted on the '
                  'device, with that passphrase, before any upload.',
              'Uploads the encrypted backup to your own iCloud Drive (iOS), '
                  'Google Drive (any platform), or Microsoft OneDrive (any '
                  'platform). You sign in to your cloud provider directly '
                  '— we never handle your cloud credentials.',
              'Stores nothing on LoadOut servers. There is no LoadOut '
                  'backend in this flow.',
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'We can\'t read your backup, and we can\'t recover a lost '
            'passphrase. If you forget it, the backup is unrecoverable. '
            'Write the passphrase down somewhere safe.',
            style: bodyStyle,
          ),
          const SizedBox(height: 16),
          Text(
            'Continuous Cloud Sync (Pro, opt-in)',
            style: subheadingStyle,
          ),
          const SizedBox(height: 8),
          Text(
            'Cloud Sync uses the same encryption model as the one-shot '
            'backup above — encrypted on this device with your '
            'passphrase, written to the same cloud folder you chose. The '
            'difference is that the upload happens automatically a few '
            'seconds after each save, and the download happens on app '
            'launch plus a manual "Sync Now" button. We never see the '
            'encrypted blob and operate no backend that receives '
            'reloading data.',
            style: bodyStyle,
          ),
          const SizedBox(height: 8),
          Text(
            'Your passphrase is cached on this device in the iOS Keychain '
            '/ Android Keystore so AutoSave can sync without re-prompting. '
            'On other devices, you enter the same passphrase to set up '
            'sync there — no LoadOut server distributes it. Lose the '
            'passphrase and the synced data is unrecoverable.',
            style: bodyStyle,
          ),
          const SizedBox(height: 24),

          Text('Sub-processors and third parties', style: headingStyle),
          const SizedBox(height: 8),
          Text(
            'We use the following third-party services to operate LoadOut. '
            'Each has its own privacy policy that governs how they handle '
            'the data we send them.',
            style: bodyStyle,
          ),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'Google Cloud / Firebase (Authentication, Hosting, Storage '
                  'for catalog updates) — '
                  'https://firebase.google.com/support/privacy',
              'RevenueCat (in-app purchase verification and entitlement) — '
                  'https://www.revenuecat.com/privacy',
              'Apple App Store and Google Play for purchase processing — '
                  'https://www.apple.com/legal/privacy/ and '
                  'https://play.google.com/about/play-terms/',
              'Sign-in providers if you use them: Google, Apple, '
                  'Microsoft, Yahoo. Each has its own privacy policy.',
            ],
          ),
          const SizedBox(height: 24),

          Text('How long we keep data', style: headingStyle),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'Reloading data: we don\'t have it — it lives on your device '
                  'for as long as you keep it there.',
              'Account record (Firebase Authentication): kept until you '
                  'ask us to delete it, or until the account is inactive '
                  'for an extended period.',
              'Purchase records (RevenueCat / the stores): kept as long '
                  'as the subscription or lifetime entitlement is active '
                  'and as required by Apple, Google, and applicable tax '
                  'law.',
            ],
          ),
          const SizedBox(height: 24),

          Text('How to delete your data', style: headingStyle),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'On-device data: open Settings → Delete my data in the app '
                  'to wipe every load, firearm, batch, brass lot, and '
                  'ballistic profile from your device. This action is '
                  'final.',
              'Account: email support@johnsondigital.com from the email '
                  'tied to your account and ask us to delete the Firebase '
                  'Authentication record. We will also ask RevenueCat to '
                  'delete the linked entitlement record.',
              'Cloud backup: delete the encrypted backup file from your '
                  'iCloud Drive or Google Drive. We can\'t see or delete '
                  'it for you.',
              'Uninstalling the app removes the local database and clears '
                  'any cached catalog updates.',
            ],
          ),
          const SizedBox(height: 24),

          Text('Your privacy rights', style: headingStyle),
          const SizedBox(height: 8),
          Text(
            'Depending on where you live, you may have additional rights '
            'over your personal information.',
            style: bodyStyle,
          ),
          const SizedBox(height: 8),
          _BulletList(
            style: bodyStyle,
            items: const [
              'European Economic Area / United Kingdom (GDPR / UK GDPR): '
                  'you have the right to access, correct, delete, '
                  'restrict, port, and object to processing of your '
                  'personal data. The lawful bases we rely on are '
                  'contract, consent (for any optional telemetry we add '
                  'later), and legitimate interest (for security and '
                  'abuse prevention). You may also lodge a complaint with '
                  'your supervisory authority.',
              'California (CCPA / CPRA): we do not sell or share your '
                  'personal information for cross-context behavioral '
                  'advertising. You have the right to know, delete, '
                  'correct, and limit use of sensitive personal '
                  'information.',
              'Other US states (CO, CT, VA, UT, etc.): we honor analogous '
                  'consumer rights to access, delete, correct, and opt '
                  'out, where applicable.',
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'To exercise any right, email support@johnsondigital.com from '
            'the address tied to your account. We will respond within the '
            'legally required window for your jurisdiction.',
            style: bodyStyle,
          ),
          const SizedBox(height: 24),

          Text('Children', style: headingStyle),
          const SizedBox(height: 8),
          Text(
            'LoadOut is not directed at children. We do not knowingly '
            'collect personal information from anyone under 18. Reloading '
            'is for adults only — see the in-app safety disclaimer.',
            style: bodyStyle,
          ),
          const SizedBox(height: 24),

          Text('International data transfers', style: headingStyle),
          const SizedBox(height: 8),
          Text(
            'Firebase Authentication and RevenueCat may process your data '
            'in the United States and other countries. Where required, we '
            'rely on Standard Contractual Clauses or equivalent mechanisms '
            'to safeguard cross-border transfers.',
            style: bodyStyle,
          ),
          const SizedBox(height: 24),

          Text('Security', style: headingStyle),
          const SizedBox(height: 8),
          Text(
            'We use TLS for any data in transit between the app and our '
            'service providers. Cloud backups are encrypted on your device '
            'with your passphrase before upload, using authenticated '
            'encryption. We do not, however, guarantee absolute security — '
            'no system is invulnerable. If we discover a breach affecting '
            'your personal information, we will notify you as required by '
            'law.',
            style: bodyStyle,
          ),
          const SizedBox(height: 24),

          Text('Changes to this policy', style: headingStyle),
          const SizedBox(height: 8),
          Text(
            'If we make material changes, we will update the effective '
            'date and surface the change in-app (typically via a re-prompt '
            'of the disclaimer / privacy dialog).',
            style: bodyStyle,
          ),
          const SizedBox(height: 24),

          Text('Contact', style: headingStyle),
          const SizedBox(height: 8),
          Text('Johnson Digital Systems — LoadOut', style: bodyStyle),
          Text('support@johnsondigital.com', style: bodyStyle),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

/// Yellow draft banner shown until counsel has approved the policy.
/// Remove this widget when the legal review is complete.
class _DraftBanner extends StatelessWidget {
  const _DraftBanner({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark
        ? scheme.tertiaryContainer.withValues(alpha: 0.4)
        : const Color(0xFFFEF3C7);
    final fg = isDark ? scheme.onTertiaryContainer : const Color(0xFF78350F);
    final border = isDark ? scheme.tertiary : const Color(0xFFF59E0B);
    return Container(
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.gavel_outlined, color: fg, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Draft — review with counsel before publication. This policy '
              'has not yet been approved by an attorney.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: fg,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
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
