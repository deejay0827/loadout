// FILE: lib/screens/auth/login_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The unauthenticated landing surface. Renders an email + password form, an
// "Or Continue With" divider, and four social provider buttons (Google,
// Apple, Microsoft, Yahoo). Beneath those sits a passwordless "Email me a
// sign-in link" affordance and a "Continue as Guest" button for anonymous
// sign-in. Email/password mode is toggleable between Sign In and Create
// Account via an inline link, and a "Forgot Password?" affordance opens a
// small dialog that prompts for an email and dispatches a Firebase password
// reset.
//
// The screen is a `StatefulWidget` because the email/password fields, the
// "creating account vs. signing in" toggle, the busy spinner, and the
// inline error text all live as widget state. Submission flows route
// through the `_runAuth` helper, which:
//
// 1. Sets `_busy = true` so every button (and the form) disables.
// 2. Awaits the supplied async callback inside a try/catch.
// 3. On `FirebaseAuthException`, surfaces the message inline.
// 4. On unrelated exceptions, runs `_isCancellation` to silently swallow
//    user-cancelled provider sheets (the Google Sign-In cancellation code,
//    the Apple `canceled` enum, and Firebase's `web-context-canceled`).
// 5. Resets `_busy = false` regardless of outcome.
//
// All seven sign-in methods share that error-handling pipeline, so the UI
// is consistent across providers.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// This is the unauthenticated branch of `_AuthGate` in `lib/app.dart`. The
// gate watches a `StreamProvider<User?>` and renders this screen whenever
// the current Firebase user is null. The disclaimer has already been
// accepted by this point in the flow, so login is the last hop before the
// user lands on `HomeScreen`.
//
// Seven sign-in methods are intentional: each one is wired through
// `AuthService` and corresponds to one configured provider in the Firebase
// project. See `CLAUDE.md` for the full list and the JWT/secret rotation
// chores that come with each.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// The cross-device email-link UX is the trickiest piece. When the user
// taps "Email me a sign-in link", `AuthService.sendEmailLink` stashes the
// email address in `SharedPreferences` under `auth.pendingEmailLinkEmail`
// before sending. When the user opens the email on the same device, the
// `app_links` deep-link handler in `lib/app.dart` reads the pending email
// and calls `AuthService.tryCompleteEmailLink`. If they open the email on
// a different device the prefs entry won't exist there, and
// `tryCompleteEmailLink` returns `EmailLinkOutcome.needsEmail`. The
// `_AuthGate` in `lib/app.dart` shows an `AlertDialog` asking for the
// email and then calls `AuthService.completeEmailLinkWithEmail` to finish
// sign-in.
//
// `_isCancellation` is also non-obvious: the three providers each surface
// "user dismissed the platform sheet" through a different exception type,
// and silently swallowing them (instead of showing an error) avoids
// flashing scary red text every time someone backs out of the Google
// chooser.
//
// `_ProviderButton` styling deserves a note: each social button is an
// `OutlinedButton.icon` with a left-aligned label, fixed 48-pixel height,
// and a `FaIcon` from `font_awesome_flutter` for brand parity. They are
// stacked rather than gridded because the labels ("Continue with Google")
// are too long to row up on a phone width.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/app.dart` (`_AuthGate.build`) — renders `LoginScreen()` whenever
//   the auth stream emits a null user.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Calls `AuthService.signIn` / `.signUp` / `.sendEmailLink` /
//   `.signInAnonymously` / `.signInWithGoogle` / `.signInWithApple` /
//   `.signInWithMicrosoft` / `.signInWithYahoo` / `.sendPasswordResetEmail`.
// - Triggers a Firebase Auth state change on success — `_AuthGate` will
//   then swap this screen for `HomeScreen` automatically.
// - Shows a `SnackBar` confirmation when an email link is sent or a
//   password reset is dispatched.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:provider/provider.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/auth_service.dart';
import '../../services/support.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSignUp = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool _isCancellation(Object error) {
    return error is GoogleSignInException &&
            error.code == GoogleSignInExceptionCode.canceled ||
        error is SignInWithAppleAuthorizationException &&
            error.code == AuthorizationErrorCode.canceled ||
        error is FirebaseAuthException && error.code == 'web-context-canceled';
  }

  Future<void> _runAuth(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message ?? e.code);
    } catch (e) {
      if (!mounted) return;
      if (_isCancellation(e)) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitEmailPassword() async {
    if (!_formKey.currentState!.validate()) return;
    final auth = context.read<AuthService>();
    final messenger = ScaffoldMessenger.of(context);
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    await _runAuth(() async {
      if (_isSignUp) {
        await auth.signUp(email, password);
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Account created. Check your inbox to verify your email.',
            ),
          ),
        );
      } else {
        await auth.signIn(email, password);
      }
    });
  }

  Future<void> _sendEmailLink() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter your email above to receive a link.');
      return;
    }
    final auth = context.read<AuthService>();
    final messenger = ScaffoldMessenger.of(context);
    await _runAuth(() async {
      await auth.sendEmailLink(email);
      messenger.showSnackBar(
        SnackBar(content: Text("Sign-in link sent to $email.")),
      );
    });
  }

  /// Cross-device email-link UX safety net (LAUNCH_CHECKLIST.md). If the
  /// user got an email-link on a phone that didn't send it, the pending-
  /// email pref isn't local and `tryCompleteEmailLink` returns null with
  /// no actionable feedback. This affordance gives them a way to ask for
  /// help without bouncing out to settings.
  Future<void> _openSupportMail() async {
    final messenger = ScaffoldMessenger.of(context);
    final subject = Uri.encodeComponent('LoadOut Sign-in Help');
    final body = Uri.encodeComponent(
      "I'm having trouble signing in. Please describe what happened "
      'and (if relevant) which email you signed in with.\n\n'
      '— — —\n'
      'App: LoadOut v1.0.0+1\n',
    );
    final uri = Uri.parse('mailto:$supportEmail?subject=$subject&body=$body');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'No email app available — write to $supportEmail.',
          ),
        ),
      );
    }
  }

  Future<void> _showForgotPassword() async {
    final auth = context.read<AuthService>();
    final messenger = ScaffoldMessenger.of(context);
    final emailController = TextEditingController(
      text: _emailController.text.trim(),
    );

    final email = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset Password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Enter your email and we'll send you a link to reset "
              'your password.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: emailController,
              decoration: const InputDecoration(labelText: 'Email'),
              keyboardType: TextInputType.emailAddress,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              emailController.text.trim(),
            ),
            child: const Text('Send'),
          ),
        ],
      ),
    );

    if (email == null || email.isEmpty) return;

    try {
      await auth.sendPasswordResetEmail(email);
      messenger.showSnackBar(
        SnackBar(content: Text('Password reset email sent to $email.')),
      );
    } on FirebaseAuthException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.message ?? e.code)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthService>();
    return Scaffold(
      appBar: AppBar(title: const Text('LoadOut')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _emailController,
                    decoration: const InputDecoration(labelText: 'Email'),
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _passwordController,
                    decoration: const InputDecoration(labelText: 'Password'),
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    validator: (v) =>
                        (v == null || v.length < 6) ? 'Min 6 chars' : null,
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _submitEmailPassword,
                    child: Text(_isSignUp ? 'Create Account' : 'Sign In'),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() => _isSignUp = !_isSignUp),
                        child: Text(
                          _isSignUp
                              ? 'Have an Account? Sign In'
                              : 'Need an Account? Sign Up',
                        ),
                      ),
                      if (!_isSignUp)
                        TextButton(
                          onPressed: _busy ? null : _showForgotPassword,
                          child: const Text('Forgot Password?'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: const [
                      Expanded(child: Divider()),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text('Or Continue With'),
                      ),
                      Expanded(child: Divider()),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // "Continue as Guest" is the FIRST option in the
                  // provider stack, with the same outlined-button
                  // shape as the social providers. The earlier card-
                  // at-the-top treatment (`_GuestCta`) made it
                  // visually distinct, but users read the difference
                  // as "this is a SECONDARY option" rather than "this
                  // is one of the equally-available sign-in methods."
                  // Keeping the same shape + height + alignment as
                  // Google / Apple / Microsoft / Yahoo gives Guest
                  // equal weight in the visual hierarchy.
                  _ProviderButton.material(
                    icon: Icons.no_accounts_outlined,
                    label: 'Continue as Guest',
                    onPressed: _busy
                        ? null
                        : () => _runAuth(auth.signInAnonymously),
                  ),
                  const SizedBox(height: 8),
                  _ProviderButton(
                    icon: FontAwesomeIcons.google,
                    label: 'Continue with Google',
                    onPressed: _busy
                        ? null
                        : () => _runAuth(auth.signInWithGoogle),
                  ),
                  const SizedBox(height: 8),
                  _ProviderButton(
                    icon: FontAwesomeIcons.apple,
                    label: 'Continue with Apple',
                    onPressed: _busy
                        ? null
                        : () => _runAuth(auth.signInWithApple),
                  ),
                  const SizedBox(height: 8),
                  _ProviderButton(
                    icon: FontAwesomeIcons.microsoft,
                    label: 'Continue with Microsoft',
                    onPressed: _busy
                        ? null
                        : () => _runAuth(auth.signInWithMicrosoft),
                  ),
                  const SizedBox(height: 8),
                  _ProviderButton(
                    icon: FontAwesomeIcons.yahoo,
                    label: 'Continue with Yahoo',
                    onPressed: _busy
                        ? null
                        : () => _runAuth(auth.signInWithYahoo),
                  ),
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: _busy ? null : _sendEmailLink,
                    icon: const Icon(Icons.link),
                    label: const Text('Email Me a Sign-In Link'),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : _openSupportMail,
                    icon: const Icon(Icons.help_outline),
                    label: const Text('Get Help Signing In'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One row in the "Or Continue With" provider stack. Same shape +
/// height + alignment for every entry — Google / Apple / Microsoft /
/// Yahoo via [_ProviderButton], "Continue as Guest" via the
/// `_ProviderButton.material` named constructor (which takes a
/// Material `IconData` instead of the `FaIconData` the social
/// providers use). All five render at the same visual weight so
/// the user reads them as equally-available options.
class _ProviderButton extends StatelessWidget {
  const _ProviderButton({
    required FaIconData icon,
    required this.label,
    required this.onPressed,
  })  : _faIcon = icon,
        _materialIcon = null;

  /// Variant for entries whose icon is a Material `IconData` rather
  /// than a `FaIconData`. Used by "Continue as Guest"
  /// (`Icons.no_accounts_outlined` is Material). Same outer shape +
  /// height + alignment as the FontAwesome variant above.
  const _ProviderButton.material({
    required IconData icon,
    required this.label,
    required this.onPressed,
  })  : _faIcon = null,
        _materialIcon = icon;

  final FaIconData? _faIcon;
  final IconData? _materialIcon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    // Icon size bumped from 18/20 to 24 so the brand glyph reads at
    // a glance — at 18px the FontAwesome marks (G, Apple, Microsoft
    // squares, Y!) were almost invisible against the dark button
    // background. 24 matches Material's standard ListTile leading
    // icon size, which is what users' eyes are calibrated to in a
    // stacked-button layout.
    final iconWidget = _faIcon != null
        ? FaIcon(_faIcon, size: 24)
        : Icon(_materialIcon, size: 24);
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: iconWidget,
      label: Text(label),
      style: OutlinedButton.styleFrom(
        // Generous horizontal padding around the icon + label group
        // so the icon isn't pressed against the rounded-rect edge.
        // Center alignment puts the (icon, label) pair in the middle
        // of the button rather than flush-left — the buttons read as
        // a peer set of options rather than a list of left-justified
        // rows.
        padding:
            const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
        alignment: Alignment.center,
        minimumSize: const Size.fromHeight(52),
      ),
    );
  }
}
