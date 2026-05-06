import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:provider/provider.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../services/auth_service.dart';

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

  Future<void> _showForgotPassword() async {
    final auth = context.read<AuthService>();
    final messenger = ScaffoldMessenger.of(context);
    final emailController = TextEditingController(
      text: _emailController.text.trim(),
    );

    final email = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset password'),
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
                    child: Text(_isSignUp ? 'Create account' : 'Sign in'),
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
                              ? 'Have an account? Sign in'
                              : 'Need an account? Sign up',
                        ),
                      ),
                      if (!_isSignUp)
                        TextButton(
                          onPressed: _busy ? null : _showForgotPassword,
                          child: const Text('Forgot password?'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: const [
                      Expanded(child: Divider()),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text('or continue with'),
                      ),
                      Expanded(child: Divider()),
                    ],
                  ),
                  const SizedBox(height: 16),
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
                    label: const Text('Email me a sign-in link'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _runAuth(auth.signInAnonymously),
                    child: const Text('Continue as guest'),
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

class _ProviderButton extends StatelessWidget {
  const _ProviderButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final FaIconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: FaIcon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
        alignment: Alignment.centerLeft,
        minimumSize: const Size.fromHeight(48),
      ),
    );
  }
}
