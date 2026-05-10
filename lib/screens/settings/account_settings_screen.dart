// FILE: lib/screens/settings/account_settings_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Settings → Account submenu. Surfaces the user's current sign-in state,
// their email (where available), a "Sign in / Sign out" affordance, and
// the "Restore purchases" button that ties RevenueCat entitlements back
// to a freshly-installed device or restored backup.
//
// Account here means the Firebase Auth identity. Sign-in is OPTIONAL —
// see CLAUDE.md "User auth posture" — so the screen has to render
// gracefully for:
//   * Signed-out users (encourage sign-in for cloud backup; sign-in is
//     handled by the LoginScreen flow elsewhere).
//   * Anonymous (guest) users — we treat them as signed out for the
//     account label, since they don't have an email.
//   * Signed-in users with a real account — show the email as the
//     subtitle on the account tile.
//
// The Restore Purchases tile is here (and was previously on the flat
// Settings list) because users with multiple devices, or who reinstalled
// LoadOut, expect to find this affordance under "Account" rather than
// hunting through Help.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The flat Settings screen had a long undifferentiated tile list. Splitting
// account / app prefs / privacy / etc. into thematic submenus (per the
// May 2026 reorganization) gives users a directory at the top level and
// reduces scrolling. This file owns the "identity + purchase recovery"
// slice of that.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/auth_service.dart';
import '../../services/biometric_service.dart';
import '../../services/entitlement_notifier.dart';
import '../../services/purchases_service.dart';
import '../../services/support.dart';

class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({super.key});

  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final isSignedIn = user != null && !user.isAnonymous;
    final accountLabel = user == null
        ? 'Not signed in'
        : user.isAnonymous
            ? 'Guest (not signed in)'
            : (user.email?.isNotEmpty == true
                ? user.email!
                : 'Signed in');
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          children: [
            ListTile(
              leading: Icon(
                isSignedIn ? Icons.account_circle : Icons.person_outline,
              ),
              title: Text(isSignedIn ? 'Email' : 'Sign in status'),
              subtitle: Text(accountLabel),
            ),
            const Divider(height: 1),
            if (!isSignedIn)
              ListTile(
                leading: const Icon(Icons.login_outlined),
                title: const Text('Sign in'),
                subtitle: const Text(
                  'Optional. Sign in to enable cloud sync, cross-device '
                  'backups, and Pro entitlement restore.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _signOutToLogin,
              )
            else
              ListTile(
                leading: const Icon(Icons.logout_outlined),
                title: const Text('Sign out'),
                subtitle: const Text(
                  'Returns you to the sign-in screen. Local data stays on '
                  'this device.',
                ),
                onTap: _signOut,
              ),
            // Biometric unlock toggle. Connected automatically to
            // whichever Firebase account the user is currently
            // signed into — biometric is a local "unlock the app"
            // gate on top of Firebase's cached refresh token. Hidden
            // entirely on devices that don't support biometric
            // (no Face ID / Touch ID / fingerprint sensor) so the
            // toggle never appears as a non-functional dead end.
            // See [BiometricService] for the full contract.
            _BiometricTile(busy: _busy, setBusy: (v) => setState(() => _busy = v)),
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
              leading: const Icon(Icons.mail_outline),
              title: const Text('Need help signing in?'),
              subtitle: const Text(
                'Email LoadOut support — we can reset access to the email '
                'you registered with.',
              ),
              onTap: _emailSupport,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _signOut() async {
    final auth = context.read<AuthService>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await auth.signOut();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Sign out failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// For signed-out users, surfacing a "Sign in" tap from inside Settings
  /// requires bouncing back to the auth shell. We sign out (no-op when
  /// already signed out) and pop everything back to the root, which lets
  /// the auth gate route to LoginScreen.
  Future<void> _signOutToLogin() async {
    final auth = context.read<AuthService>();
    setState(() => _busy = true);
    try {
      await auth.signOut();
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (_) {
      // Already signed out / anonymous — ignore.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
            isPro ? 'Pro restored.' : 'No purchases found on this account.',
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

  Future<void> _emailSupport() async {
    final subject = Uri.encodeComponent('LoadOut sign-in help');
    final body = Uri.encodeComponent(
      'Describe the issue here.\n\n'
      'I am having trouble signing in. My account email is:\n',
    );
    final uri = Uri.parse('mailto:$supportEmail?subject=$subject&body=$body');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No email app available — write to $supportEmail.')),
      );
    }
  }
}

/// Settings tile for the "Use biometrics to unlock LoadOut" toggle.
/// Hidden when the device reports no biometric support (no Face ID
/// / Touch ID / fingerprint sensor enrolled) so the toggle never
/// appears as a non-functional control. Reads / writes through
/// [BiometricService]; the service itself runs a confirmation
/// biometric prompt as part of the enable flow so we never enable
/// a feature the user can't actually use.
class _BiometricTile extends StatelessWidget {
  const _BiometricTile({required this.busy, required this.setBusy});

  final bool busy;
  final void Function(bool) setBusy;

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<BiometricService>();
    if (!svc.isHydrated || !svc.isAvailable) {
      // Not yet probed, or device doesn't expose biometric. Either
      // way we render nothing — the user shouldn't see a toggle they
      // can't engage. Once hydration completes a rebuild fires
      // automatically (the service is a ChangeNotifier).
      return const SizedBox.shrink();
    }
    // Biometric is not offered to anonymous users. The Firebase
    // anonymous account is device-local — losing the device loses
    // the account, so a "biometric unlock" sells the user a sense
    // of security that the underlying account doesn't actually
    // provide. Sign-out + sign-in cycles also discard the anonymous
    // user, so the biometric flag would be associated with whatever
    // anonymous UID happened to be active when the user toggled it.
    // Hiding the tile is cleaner than disabling it — no toggle = no
    // implication that biometric is "available, you just have to
    // upgrade." Users with a real account see the toggle as before.
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.isAnonymous) {
      return const SizedBox.shrink();
    }
    return SwitchListTile(
      secondary: const Icon(Icons.fingerprint),
      title: const Text('Unlock With Biometrics'),
      subtitle: const Text(
        "Use Face ID, Touch ID, or your device's fingerprint to "
        'unlock LoadOut. Connected to your current sign-in — no '
        'separate password to remember.',
      ),
      value: svc.isEnabled,
      onChanged: busy
          ? null
          : (value) async {
              setBusy(true);
              try {
                final ok = await svc.setEnabled(value);
                if (!ok && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Biometric authentication did not complete. '
                        'Toggle stayed off.',
                      ),
                    ),
                  );
                }
              } finally {
                setBusy(false);
              }
            },
    );
  }
}
